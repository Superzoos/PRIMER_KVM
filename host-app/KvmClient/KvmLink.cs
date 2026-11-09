using System.Buffers;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace KvmClient;

/// <summary>Состояние устройства из ответа на KVM_CMD_STATUS.</summary>
public sealed record DeviceStatus(
    uint UptimeMs, uint CpuHz, uint RxFrames, uint RxErrors, uint RxDropped,
    uint TxFrames, uint TmdsKhz, string Firmware, uint DdrMb, uint VidFrames, uint VidPackets,
    uint HdmiFlags, uint HdmiRes, uint UsbFlags, TimeSpan Rtt);

/// <summary>Результат запроса обновления.</summary>
public enum UpdateResult { Started = 0, Busy = 1, NoVideo = 2, NoReply = -1, Lost = -2 }

/// <summary>Ответ на KVM_CMD_UPDATE: источник (0 - тестовая картинка, 1 - захват HDMI), номер, число плиток.</summary>
public sealed record UpdateInfo(int Source, int Upd, int Tiles, int TileW, int TileH, int Width, int Height);

/// <summary>Плитка: столбец, ряд и пиксели BGRA (TileW * TileH, строки сверху вниз; массив из ArrayPool).</summary>
public readonly record struct Tile(int Tx, int Ty, int[] Pixels);

/// <summary>Все плитки одного обновления (собраны полностью). После применения - Release().</summary>
public sealed class TileSet
{
    public int Upd { get; init; }
    public List<Tile> Tiles { get; } = new();
    public void Release()
    {
        foreach (var t in Tiles) ArrayPool<int>.Shared.Return(t.Pixels);
        Tiles.Clear();
    }
}

/// <summary>
/// Протокол KVM поверх UDP (описание - firmware/app/kvm_proto.h). Все поля little-endian.
/// Управление: заголовок 8 байт "KVM1", cmd, flags, seq; ответ - cmd | 0x80, тот же seq.
/// Видео: обновления из плиток (KVM_CMD_UPDATE); пакеты "KVT1" (заголовок 22 байта + плитка RGB565) приходят
/// на тот же сокет. Приём - в отдельном потоке; ответы сопоставляются с запросами по seq, плитки собираются
/// по номеру обновления; обновление отдаётся, только когда получены все его плитки.
/// </summary>
public sealed class KvmLink : IDisposable
{
    public const uint Magic = 0x314D564B;      // 'K','V','M','1'
    public const uint TileMagic = 0x3154564B;  // 'K','V','T','1'
    public const byte CmdStatus = 0x01;
    public const byte CmdEcho = 0x02;
    public const byte CmdUpdate = 0x04;
    public const byte CmdInput = 0x05;
    public const byte UpdFull = 0x01;
    public const byte Reply = 0x80;
    private const int HeaderLen = 8;
    private const int StatusLenV1 = 7 * 4 + 24;   // прошивки до DDR3
    private const int StatusLen = StatusLenV1 + 12;      // + DDR3 и видео
    private const int StatusLenV3 = StatusLen + 8;       // + HDMI
    private const int StatusLenV4 = StatusLenV3 + 4;     // + USB
    private const int UpdateReplyLen = 20;
    private const int TileHeaderLen = 22;

    private readonly Socket _sock;
    private readonly IPEndPoint _device;
    private readonly Thread _rxThread;
    private readonly ConcurrentDictionary<ushort, TaskCompletionSource<byte[]>> _pending = new();
    private readonly object _vlock = new();
    private int _seq;
    private volatile bool _disposed;

    // сборка обновления (под _vlock)
    private sealed class TileAssembly
    {
        public required int Upd, Count;
        public required bool[] Have;
        public int Received;
        public required TileSet Set;
    }
    private TileAssembly? _asm;                      // собирается
    private TileSet? _done;                      // последнее собранное, ещё не забранное
    private TaskCompletionSource _doneSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _tileW = 32, _tileH = 16;        // из ответа на KVM_CMD_UPDATE

    // RGB565 -> 8 бит на канал
    private static readonly byte[] T5 = Enumerable.Range(0, 32).Select(v => (byte)((v * 255 + 15) / 31)).ToArray();
    private static readonly byte[] T6 = Enumerable.Range(0, 64).Select(v => (byte)((v * 255 + 31) / 63)).ToArray();

    /// <summary>Локальный адрес, с которого идут запросы (null - выбирает Windows).</summary>
    public IPAddress? LocalAddress { get; }

    /// <summary>Принято пакетов плиток / отброшено (не от устройства, битые).</summary>
    public long VideoPackets => Interlocked.Read(ref _videoPackets);
    public long BadPackets => Interlocked.Read(ref _badPackets);
    private long _videoPackets, _badPackets;

    /// <summary>Сколько прошло с последнего пакета от устройства (любого).</summary>
    public TimeSpan SinceLastRx =>
        TimeSpan.FromSeconds((Stopwatch.GetTimestamp() - Interlocked.Read(ref _lastRx)) / (double)Stopwatch.Frequency);
    private long _lastRx = Stopwatch.GetTimestamp() - Stopwatch.Frequency * 60;

    public KvmLink(IPEndPoint device)
    {
        _device = device;
        // Запросы отправляются с адреса ПК из той же подсети, что и плата: Windows отправит их
        // через этот адаптер, даже если VPN забирает себе маршрут по умолчанию.
        LocalAddress = FindLocalAddress(device.Address);
        _sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        _sock.ReceiveBufferSize = 16 * 1024 * 1024;   // полное обновление 1280x720 - ~2 МБ, приходит за ~0.16 с
        if (OperatingSystem.IsWindows())
            _sock.IOControl(unchecked((int)0x9800000C), new byte[] { 0 }, null);   // SIO_UDP_CONNRESET выкл.: ICMP не рвёт приём
        _sock.Bind(new IPEndPoint(LocalAddress ?? IPAddress.Any, 0));
        _rxThread = new Thread(ReceiveLoop) { IsBackground = true, Name = "KvmLink RX" };
        _rxThread.Start();
    }

    /// <summary>Адрес IPv4 работающего адаптера ПК в одной подсети с указанным адресом.</summary>
    public static IPAddress? FindLocalAddress(IPAddress remote)
    {
        if (remote.AddressFamily != AddressFamily.InterNetwork) return null;
        var r = remote.GetAddressBytes();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.Address.Equals(remote)) continue;
                var a = ua.Address.GetAddressBytes();
                var m = ua.IPv4Mask.GetAddressBytes();
                var same = true;
                for (var i = 0; i < 4; i++) same &= (a[i] & m[i]) == (r[i] & m[i]);
                if (same) return ua.Address;
            }
        }
        return null;
    }

    // ---------------- Управление ----------------

    /// <summary>Отправить команду и дождаться ответа. Возвращает данные ответа (без заголовка) или null.</summary>
    private async Task<byte[]?> RequestAsync(byte cmd, TimeSpan timeout, CancellationToken ct, byte flags = 0)
    {
        var seq = (ushort)Interlocked.Increment(ref _seq);
        var tcs = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[seq] = tcs;
        var req = new byte[HeaderLen];
        BinaryPrimitives.WriteUInt32LittleEndian(req, Magic);
        req[4] = cmd;
        req[5] = flags;
        BinaryPrimitives.WriteUInt16LittleEndian(req.AsSpan(6), seq);
        try
        {
            await _sock.SendToAsync(req, SocketFlags.None, _device, ct);
            var done = await Task.WhenAny(tcs.Task, Task.Delay(timeout, ct));
            return done == tcs.Task ? tcs.Task.Result : null;
        }
        catch (OperationCanceledException) { return null; }
        catch (SocketException) { return null; }
        catch (ObjectDisposedException) { return null; }
        finally { _pending.TryRemove(seq, out _); }
    }

    public async Task<DeviceStatus?> RequestStatusAsync(TimeSpan timeout, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var s = await RequestAsync(CmdStatus, timeout, ct);
        if (s == null || s.Length < StatusLenV1) return null;
        var fw = s.AsSpan(28, 24);
        var z = fw.IndexOf((byte)0);
        var ext = s.Length >= StatusLen;
        var ext3 = s.Length >= StatusLenV3;
        var ext4 = s.Length >= StatusLenV4;
        return new DeviceStatus(U(s, 0), U(s, 4), U(s, 8), U(s, 12), U(s, 16), U(s, 20), U(s, 24),
            Encoding.ASCII.GetString(z >= 0 ? fw[..z] : fw),
            ext ? U(s, 52) : 0, ext ? U(s, 56) : 0, ext ? U(s, 60) : 0,
            ext3 ? U(s, 64) : 0, ext3 ? U(s, 68) : 0, ext4 ? U(s, 72) : 0, sw.Elapsed);
    }

    /// <summary>Состояние клавиатуры и мыши (kvm_input_t, 16 байт) - без ответа.</summary>
    public void SendInput(byte[] payload)
    {
        var req = new byte[HeaderLen + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(req, Magic);
        req[4] = CmdInput;
        BinaryPrimitives.WriteUInt16LittleEndian(req.AsSpan(6), (ushort)Interlocked.Increment(ref _seq));
        payload.CopyTo(req, HeaderLen);
        try { _sock.SendTo(req, SocketFlags.None, _device); }
        catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }

    /// <summary>
    /// Запросить обновление (full - все плитки) и дождаться всех его плиток. Started: info и плитки (пустой
    /// набор, если изменений нет); Lost - не все плитки пришли за dataTimeout (нужно запросить full).
    /// </summary>
    public async Task<(UpdateResult Result, UpdateInfo? Info, TileSet? Tiles)> GrabUpdateAsync(
        bool full, TimeSpan replyTimeout, TimeSpan dataTimeout, CancellationToken ct)
    {
        try
        {
            var r = await RequestAsync(CmdUpdate, replyTimeout, ct, full ? UpdFull : (byte)0);
            if (r == null || r.Length < UpdateReplyLen) return (UpdateResult.NoReply, null, null);
            var result = (UpdateResult)r[0];
            var info = new UpdateInfo(r[1], R16(r, 2), R16(r, 4), R16(r, 6), R16(r, 8), R16(r, 10), R16(r, 12));
            if (result != UpdateResult.Started) return (result, info, null);
            if (info.TileW == 0 || info.TileH == 0 || info.Width == 0 || info.Height == 0)
                return (UpdateResult.NoReply, null, null);
            lock (_vlock) { _tileW = info.TileW; _tileH = info.TileH; }
            if (info.Tiles == 0) return (result, info, new TileSet { Upd = info.Upd });

            var deadline = Stopwatch.GetTimestamp() + (long)(dataTimeout.TotalSeconds * Stopwatch.Frequency);
            while (true)
            {
                Task signal;
                lock (_vlock)
                {
                    if (_done != null && _done.Upd == info.Upd)
                    {
                        var d = _done;
                        _done = null;
                        return (result, info, d);
                    }
                    signal = _doneSignal.Task;
                }
                var left = TimeSpan.FromSeconds((deadline - Stopwatch.GetTimestamp()) / (double)Stopwatch.Frequency);
                if (left <= TimeSpan.Zero || await Task.WhenAny(signal, Task.Delay(left, ct)) != signal)
                    return (UpdateResult.Lost, info, null);
            }
        }
        catch (OperationCanceledException) { return (UpdateResult.NoReply, null, null); }
    }

    private static uint U(byte[] s, int off) => BinaryPrimitives.ReadUInt32LittleEndian(s.AsSpan(off));
    private static int R16(byte[] s, int off) => BinaryPrimitives.ReadUInt16LittleEndian(s.AsSpan(off));

    // ---------------- Приём ----------------

    private void ReceiveLoop()
    {
        var buf = new byte[2048];
        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
        while (!_disposed)
        {
            int n;
            try { n = _sock.ReceiveFrom(buf, ref from); }
            catch (SocketException) { continue; }          // например, ICMP "порт недоступен"
            catch (ObjectDisposedException) { break; }
            if (!((IPEndPoint)from).Address.Equals(_device.Address) || n < HeaderLen)
            {
                Interlocked.Increment(ref _badPackets);
                continue;
            }
            Interlocked.Exchange(ref _lastRx, Stopwatch.GetTimestamp());
            var magic = BinaryPrimitives.ReadUInt32LittleEndian(buf);
            if (magic == TileMagic) OnTile(buf.AsSpan(0, n));
            else if (magic == Magic && (buf[4] & Reply) != 0)
            {
                var seq = BinaryPrimitives.ReadUInt16LittleEndian(buf.AsSpan(6));
                if (_pending.TryGetValue(seq, out var tcs)) tcs.TrySetResult(buf.AsSpan(HeaderLen, n - HeaderLen).ToArray());
            }
            else Interlocked.Increment(ref _badPackets);
        }
    }

    private void OnTile(ReadOnlySpan<byte> p)
    {
        if (p.Length < TileHeaderLen) { Interlocked.Increment(ref _badPackets); return; }
        int upd = R16(p, 4), tx = R16(p, 6), ty = R16(p, 8), index = R16(p, 10), count = R16(p, 12);
        int w = R16(p, 14), h = R16(p, 16), format = R16(p, 18);
        lock (_vlock)
        {
            int tw = _tileW, th = _tileH, n = tw * th;
            if (format != 1 || count == 0 || index >= count || tx * tw >= w || ty * th >= h ||
                p.Length < TileHeaderLen + n * 2)
            {
                Interlocked.Increment(ref _badPackets);
                return;
            }
            Interlocked.Increment(ref _videoPackets);

            if (_asm == null || _asm.Upd != upd || _asm.Count != count)
            {
                _asm?.Set.Release();                        // прежнее обновление не собралось
                _asm = new TileAssembly { Upd = upd, Count = count, Have = new bool[count], Set = new TileSet { Upd = upd } };
            }
            if (_asm.Have[index]) return;                   // повтор
            var px = ArrayPool<int>.Shared.Rent(n);
            var src = p.Slice(TileHeaderLen, n * 2);
            for (var i = 0; i < n; i++)
            {
                var v = src[2 * i] | (src[2 * i + 1] << 8);
                px[i] = unchecked((int)0xFF000000) | (T5[v >> 11] << 16) | (T6[(v >> 5) & 63] << 8) | T5[v & 31];
            }
            _asm.Set.Tiles.Add(new Tile(tx, ty, px));
            _asm.Have[index] = true;
            if (++_asm.Received == count)
            {
                _done?.Release();
                _done = _asm.Set;
                _asm = null;
                var s = _doneSignal;
                _doneSignal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                s.TrySetResult();
            }
        }
    }

    private static int R16(ReadOnlySpan<byte> p, int off) => BinaryPrimitives.ReadUInt16LittleEndian(p.Slice(off));

    public void Dispose()
    {
        _disposed = true;
        _sock.Dispose();
        foreach (var t in _pending.Values) t.TrySetCanceled();
    }
}
