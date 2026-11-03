unit PSP.Net;

// The network libraries as a PSP sees them with nowhere to connect to:
// sceNet, sceWlanDrv, sceNetApctl (no access points, no profiles),
// sceNetResolver (no DNS server), sceHttp and sceSsl, sceParseUri,
// sceNetInet with its loopback interface (sockets on 127.0.0.1 talk to each
// other as on hardware), ad hoc with nobody else around, and sceUsb with no
// cable. The libraries' own threads (apctl's and adhocctl's event threads)
// are guest threads running a stub that calls back into the service.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, PSP.Types,
  PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service,
  PSP.State.Action;

type
  TNetCall = record
    Func: Cardinal;
    Args: TArray<Cardinal>;
  end;

  // Work for a library thread: changes its state, then returns the guest
  // calls (handlers) to make.
  TNetJob = record
    Action: IPSPStateAction;
  end;

  TPSPNetWorker = class
  public
    Thread: TPSPThread;
    Jobs: TQueue<TNetJob>;
    Calls: TQueue<TNetCall>;
    constructor Create;
    destructor Destroy; override;
  end;

  TNetResolver = class
  public
    Id: Integer;
    // An async lookup's result waiting to be collected.
    Pending: Boolean;
    PendingResult: Cardinal;
  end;

  TNetHandler = record
    Used: Boolean;
    Func, Arg: Cardinal;
  end;

  TInetDatagram = record
    Data: TBytes;
    FromIP: Cardinal;
    FromPort: Integer;
  end;

  TInetState = (isClosed, isListening, isConnecting, isEstablished);

  TInetSocket = class
  public
    Fd: Integer;
    // 1 stream, 2 datagram, 3 raw.
    Kind: Integer;
    LocalIP: Cardinal;
    LocalPort: Integer;
    Bound: Boolean;
    PeerIP: Cardinal;
    PeerPort: Integer;
    HasPeer: Boolean;
    // SO_* flags as the stack keeps them.
    Options: Cardinal;
    LingerTime: Integer;
    SndBuf, RcvBuf, SndLowat, RcvLowat: Integer;
    // In ticks of 10 ms.
    SndTimeo, RcvTimeo: Integer;
    NBIO, NoDelay: Boolean;
    TTL: Integer;
    SoError: Integer;
    // The descriptor is closed; a connection can outlive it.
    Closed: Boolean;
    Datagrams: TQueue<TInetDatagram>;
    QueuedBytes: Integer;
    State: TInetState;
    ListenFailed, ConnectFailed: Boolean;
    Backlog: Integer;
    // Connections the listener has completed, and those waiting for room.
    AcceptQueue, SynQueue: TList<TInetSocket>;
    Peer: TInetSocket;
    RecvData, SendData: TBytes;
    RecvLen, SendLen: Integer;
    ReadShut, WriteShut, CantRecvMore, CantSendMore: Boolean;
    FinPending, FinReceived: Boolean;
    TransferScheduled: Boolean;
    constructor Create(AKind: Integer);
    destructor Destroy; override;
  end;

  // A thread blocked in a socket call; Attempt finishes the call when it can
  // (or must: on its timeout), giving the result and errno.
  TInetAttempt = IPSPStateAction;

  TInetWaiter = class
  public
    Thread: TPSPThread;
    Sock: TInetSocket;
    Attempt: TInetAttempt;
    Timer: Int64;
  end;

  TAdhocMac = array[0..5] of Byte;

  TAdhocDatagram = record
    Data: TBytes;
    Port: Integer;
  end;

  // A PDP or PTP socket of sceNetAdhoc.
  TAdhocSocket = class
  public
    Id: Integer;
    Ptp: Boolean;
    Port: Integer;
    BufSize: Integer;
    Alert: Cardinal;
    Deleted: Boolean;
    Queue: TQueue<TAdhocDatagram>;
    QueuedBytes: Integer;
    // PTP: 0 closed, 1 listening, 2 SYN sent, 4 established.
    State: Integer;
    PeerMac: TAdhocMac;
    PeerPort: Integer;
    Pending: TList<TAdhocSocket>;
    Peer: TAdhocSocket;
    RecvData: TBytes;
    RecvLen: Integer;
    PeerClosed, Refused: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TMatchingContext = class
  public
    Id: Integer;
    Mode, MaxNum, Port: Integer;
    Running: Boolean;
    HelloOpt: TBytes;
  end;

  TPSPNet = class(TPSPService)
  private
    FWorkerIndex: Integer;
    FWorkerStub: Cardinal;
    FWorkers: TObjectList<TPSPNetWorker>;
    // sceNet
    FNetInited: Boolean;
    FPoolSize: Cardinal;
    // sceNetApctl
    FApctlInited: Boolean;
    FApctlState: Integer;
    FApctlHandlers: array[0..1] of TNetHandler;
    FApctlWorker: TPSPNetWorker;
    FScanning: Boolean;
    FScanTimer: Int64;
    // sceNetResolver
    FResolverInited: Boolean;
    FResolvers: TObjectDictionary<Integer, TNetResolver>;
    FNextResolver: Integer;
    // sceHttp
    FHttpInited: Boolean;
    FHttpIds: TDictionary<Cardinal, Integer>;
    FNextTemplate, FNextConnection, FNextRequest: Cardinal;
    // sceUsb
    FUsbStarted, FUsbActivated: Boolean;
    // sceNetInet
    FInetInited: Boolean;
    // Open descriptors; every socket the stack still has (closed ones
    // finishing their connection, accepted ones not yet handed out).
    FSockets: TDictionary<Integer, TInetSocket>;
    FPcbs: TList<TInetSocket>;
    // Sockets the stack is done with, kept until reset: pending events and
    // waiters may still look at them.
    FDeadPcbs: TObjectList<TInetSocket>;
    FWaiters: TObjectList<TInetWaiter>;
    FNextFd: Integer;
    FNextEphemeral: Integer;
    FErrno: TDictionary<Cardinal, Integer>;
    // sceNetAdhocctl
    FAdhocctlInited, FAdhocctlBroken: Boolean;
    FAdhocctlState: Integer;
    FAdhocctlWorker: TPSPNetWorker;
    FAdhocctlHandlers: array[0..3] of TNetHandler;
    FAdhocId: TBytes;
    FAdhocGroup: RawByteString;
    // The WLAN device has been brought up by a group operation.
    FAdhocDeviceUp: Boolean;
    FGameModePending: Boolean;
    FGameModeTimer: Int64;
    // sceNetAdhocDiscover
    FDiscoverStatus, FDiscoverPhase: Integer;
    FDiscoverParam: Cardinal;
    // sceNetAdhoc
    FAdhocInited: Boolean;
    FAdhocObjs: TList<TAdhocSocket>;
    FAdhocDead: TObjectList<TAdhocSocket>;
    FNextAdhocId: Integer;
    FNextAdhocPort: Integer;
    // sceNetAdhocMatching
    FMatchingInited: Boolean;
    FMatchingPool: Cardinal;
    FMatching: TObjectDictionary<Integer, TMatchingContext>;
    FLastMatchingId: Integer;
    procedure hWorker;
    function StartWorker(const Name: string; Priority: Integer; StackSize: Cardinal): TPSPNetWorker;
    procedure StopWorker(var W: TPSPNetWorker);
    procedure Post(W: TPSPNetWorker; const Job: IPSPStateAction);
    function WorkerById(Id: Cardinal): TPSPNetWorker;
    procedure QueueCalls(W: TPSPNetWorker; const Work: TArray<TNetCall>);
    procedure StateNetJob(Action: TPSPStateAction; Value: Cardinal);
    procedure StateAdhocEvent(Action: TPSPStateAction; Value: Cardinal);
    procedure StateAdhocChange(Action: TPSPStateAction; Value: Cardinal);
    procedure StateGameModeTimeout(Action: TPSPStateAction; Value: Cardinal);
    procedure StateScanTimer(Action: TPSPStateAction; Value: Cardinal);
    function Calls(const Handlers: array of TNetHandler; const Args: array of Cardinal): TArray<TNetCall>;
    // sceParseUri
    procedure hUriParse;
    procedure hUriBuild;
    procedure hUriEscape;
    procedure hUriUnescape;
    // sceNet
    procedure hNetInit;
    procedure hNetTerm;
    procedure hNetEtherNtostr;
    procedure hNetEtherStrton;
    procedure hNetGetLocalEtherAddr;
    procedure hNetGetMallocStat;
    procedure hNetThreadAbort;
    procedure hNetFreeThreadinfo;
    // sceWlanDrv
    procedure hWlanGetSwitchState;
    procedure hWlanDevIsPowerOn;
    procedure hWlanGetEtherAddr;
    // sceNetApctl
    procedure ApctlSetState(NewState, Event: Integer);
    procedure hApctlInit;
    procedure hApctlTerm;
    procedure hApctlGetState;
    procedure hApctlGetInfo;
    procedure hApctlAddHandler;
    procedure hApctlDelHandler;
    procedure hApctlConnect;
    procedure hApctlDisconnect;
    procedure hApctlScanUser;
    procedure hApctlGetBSSDescIDListUser;
    procedure hApctlGetBSSDescEntryUser;
    procedure hNotExported;
    // sceNetResolver
    function ResolverOf(Id: Integer): TNetResolver;
    procedure hResolverInit;
    procedure hResolverTerm;
    procedure hResolverCreate;
    procedure hResolverDelete;
    procedure hResolverStartNtoA;
    procedure hResolverStartAtoN;
    procedure hResolverStartNtoAAsync;
    procedure hResolverStartAtoNAsync;
    procedure hResolverPollAsync;
    procedure hResolverWaitAsync;
    procedure hResolverStop;
    // sceHttp
    function HttpId(Kind: Integer; out Id: Cardinal): Boolean;
    procedure hHttpInit;
    procedure hHttpEnd;
    procedure hHttpCreateTemplate;
    procedure hHttpCreateConnection;
    procedure hHttpCreateRequest;
    procedure hHttpDeleteTemplate;
    procedure hHttpDeleteConnection;
    procedure hHttpDeleteRequest;
    procedure hHttpSendRequest;
    procedure hHttpGetContentLength;
    procedure hHttpGetStatusCode;
    procedure hHttpReadData;
    procedure hHttpSetting;
    procedure hZero;
    // sceUsb
    procedure hUsbStart;
    procedure hUsbActivate;
    procedure hUsbDeactivate;
    procedure hUsbGetState;
    procedure hUsbWaitState;
    // sceNetInet
    procedure InetReset;
    procedure InetRegister;
    procedure InetAbortThread(T: TPSPThread);
    procedure SetErrnoOf(T: TPSPThread; Err: Integer);
    procedure InetFail(Err: Integer);
    procedure InetOk(Value: Integer);
    function SockOf(Fd: Integer): TInetSocket;
    function NewFd: Integer;
    function NewSock(Kind: Integer): TInetSocket;
    procedure DropPcb(S: TInetSocket);
    function EphemeralPort(Kind: Integer): Integer;
    function PortInUse(Kind: Integer; IP: Cardinal; Port: Integer; Self_: TInetSocket): Boolean;
    function ReadAddr(Addr: Cardinal; out IP: Cardinal; out Port: Integer): Boolean;
    procedure WriteAddr(Addr, LenPtr: Cardinal; IP: Cardinal; Port: Integer);
    procedure Later(const Event: IPSPStateAction);
    procedure StateLater(Action: TPSPStateAction; Value: Cardinal);
    procedure StateSocketEvent(Action: TPSPStateAction; Value: Cardinal);
    procedure StateDatagram(Action: TPSPStateAction; Value: Cardinal);
    procedure StateSynRetry(Action: TPSPStateAction; Value: Cardinal);
    procedure StateWaitTimeout(Action: TPSPStateAction; Value: Cardinal);
    function NewAttempt(const Kind: string; const Objects: array of TObject; const Args: array of Int64): TInetAttempt;
    function TryAttempt(const Work: TInetAttempt; Final: Boolean; out Ret, Err: Integer): Boolean;
    procedure StateAttempt(Action: TPSPStateAction; Value: Cardinal);
    procedure Scatter(Action: TPSPStateAction; const Src: TBytes; Count: Integer);
    function TrySend(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryRecvDatagram(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryRecvStream(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryAccept(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryConnect(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TrySelect(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryPoll(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryPdpRecv(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryPtpConnect(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryPtpAccept(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryPtpRecv(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    function TryAdhocPoll(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
    procedure InetWake;
    procedure FinishWaiter(W: TInetWaiter; Final: Boolean);
    procedure InetWaitAbort(T: TPSPThread);
    procedure Run(S: TInetSocket; TimeoutNs: Int64; NonBlocking: Boolean; const Attempt: TInetAttempt);
    procedure ScheduleTransfer(S: TInetSocket);
    procedure Transfer(S: TInetSocket);
    procedure PeerReset(S: TInetSocket);
    procedure Handshake(C: TInetSocket);
    function FindListener(IP: Cardinal; Port: Integer): TInetSocket;
    function QueueRoom(L: TInetSocket): Boolean;
    procedure Establish(L, C: TInetSocket);
    procedure CloseSocket(S: TInetSocket; Reset: Boolean);
    function Readable(S: TInetSocket): Boolean;
    function Writable(S: TInetSocket): Boolean;
    procedure SendCall(Fd: Integer; const Data: TBytes; Flags: Integer; HasTo: Boolean; ToIP: Cardinal; ToPort: Integer);
    procedure RecvCall(Fd: Integer; const Segs: TArray<TPair<Cardinal, Integer>>; Flags: Integer; FromPtr, FromLenPtr, MsgFlagsPtr: Cardinal);
    procedure DeliverDatagram(S: TInetSocket; const Data: TBytes; ToIP: Cardinal; ToPort: Integer);
    procedure CbStat(Stream: Boolean);
    procedure hInetInit;
    procedure hInetTerm;
    procedure hInetSocket;
    procedure hInetBind;
    procedure hInetListen;
    procedure hInetAccept;
    procedure hInetConnect;
    procedure hInetSend;
    procedure hInetSendto;
    procedure hInetSendmsg;
    procedure hInetRecv;
    procedure hInetRecvfrom;
    procedure hInetRecvmsg;
    procedure hInetClose;
    procedure hInetCloseWithRST;
    procedure hInetShutdown;
    procedure hInetGetsockname;
    procedure hInetGetpeername;
    procedure hInetSetsockopt;
    procedure hInetGetsockopt;
    procedure hInetSelect;
    procedure hInetPoll;
    procedure hInetGetErrno;
    procedure hInetGetPspError;
    procedure hInetSocketAbort;
    procedure hInetGetUdpcbstat;
    procedure hInetGetTcpcbstat;
    procedure hInetInetAddr;
    procedure hInetInetAton;
    procedure hInetInetPton;
    procedure hInetInetNtop;

    // Ad hoc
    procedure AdhocReset;
    procedure AdhocRegister;
    procedure AdhocctlEvent(Event: Integer; Error: Cardinal; DelayNs: Int64; const Change: IPSPStateAction);
    function AdhocctlReady: Boolean;
    function ValidGroupName(Ptr: Cardinal; out Name: RawByteString): Boolean;
    function ReadMac(Addr: Cardinal): TAdhocMac;
    function IsLocalMac(const M: TAdhocMac): Boolean;
    function MacKind(const M: TAdhocMac): Integer;
    function AdhocObj(Id: Integer): TAdhocSocket;
    function AdhocNewId: Integer;
    function AdhocCount: Integer;
    function AdhocPortUsed(Ptp: Boolean; Port: Integer): Boolean;
    procedure AdhocWait(TimeoutUs: Cardinal; NonBlocking: Boolean; const Attempt: TInetAttempt);
    procedure AdhocDrop(S: TAdhocSocket);
    function PtpListenerFor(Port: Integer): TAdhocSocket;
    procedure hAdhocctlInit;
    procedure hAdhocctlTerm;
    procedure hAdhocctlAddHandler;
    procedure hAdhocctlDelHandler;
    procedure hAdhocctlGetState;
    procedure hAdhocctlCreate;
    procedure hAdhocctlConnect;
    procedure hAdhocctlJoin;
    procedure hAdhocctlScan;
    procedure hAdhocctlDisconnect;
    procedure hAdhocctlGetParameter;
    procedure hAdhocctlGetPeerList;
    procedure hAdhocctlGetPeerInfo;
    procedure hAdhocctlGetScanInfo;
    procedure hAdhocctlGetAdhocId;
    procedure hAdhocctlGetNameByAddr;
    procedure hAdhocctlGetAddrByName;
    procedure GameModeEnter(Group: Cardinal; TimeoutUs: Cardinal; const Members: TAdhocMac; HasMembers: Boolean);
    procedure hAdhocctlCreateEnterGameMode;
    procedure hAdhocctlCreateEnterGameModeMin;
    procedure hAdhocctlJoinEnterGameMode;
    procedure hAdhocctlExitGameMode;
    procedure hAdhocctlGetGameModeInfo;
    procedure hGameModeNotInMode;
    procedure hGameModeDeleteNotInMode;
    procedure hDiscoverInitStart;
    procedure hDiscoverUpdate;
    procedure hDiscoverGetStatus;
    procedure hDiscoverStop;
    procedure hDiscoverTerm;
    procedure hDiscoverRequestSuspend;
    procedure hAdhocInit;
    procedure hAdhocTerm;
    procedure hPdpCreate;
    procedure hPdpSend;
    procedure hPdpRecv;
    procedure hPdpDelete;
    procedure hGetPdpStat;
    procedure hPtpOpen;
    procedure hPtpListen;
    procedure hPtpConnect;
    procedure hPtpAccept;
    procedure hPtpSend;
    procedure hPtpRecv;
    procedure hPtpFlush;
    procedure hPtpClose;
    procedure hGetPtpStat;
    procedure hSetSocketAlert;
    procedure hGetSocketAlert;
    procedure hPollSocket;
    procedure hMatchingInit;
    procedure hMatchingTerm;
    procedure hMatchingCreate;
    procedure MatchingStart(Id, StackA, StackB: Integer; PartA, PartB: Integer; OptLen: Integer; Opt: Cardinal);
    procedure hMatchingStart;
    procedure hMatchingStart2;
    procedure hMatchingStop;
    procedure hMatchingDelete;
    procedure hMatchingRunning;
    procedure hMatchingSetHelloOpt;
    procedure hMatchingGetHelloOpt;
    procedure hMatchingGetMembers;
    procedure hMatchingGetPoolMaxAlloc;
    procedure hMatchingGetPoolStat;

  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  PSP.Settings, System.Classes;

const
  // The console's own MAC address.
  PSPEtherAddr: TAdhocMac = ($00, $1F, $A7, $52, $4D, $50);
  SCE_NET_ERROR_INVALID_ARG = Cardinal($80410103);
  SCE_NET_ERROR_INVALID_THREAD = Cardinal($80410104);
  SCE_NET_APCTL_ERROR_ALREADY_INITIALIZED = Cardinal($80410A01);
  SCE_NET_APCTL_ERROR_INVALID_CODE = Cardinal($80410A02);
  SCE_NET_APCTL_ERROR_INVALID_ARG = Cardinal($80410A03);
  SCE_NET_APCTL_ERROR_NOT_CONNECTED = Cardinal($80410A05);
  SCE_NET_APCTL_ERROR_HANDLER_NOT_FOUND = Cardinal($80410A09);
  SCE_NET_APCTL_ERROR_NOT_INITIALIZED = Cardinal($80410A0D);
  SCE_NET_APCTL_ERROR_TOO_MANY_HANDLERS = Cardinal($80410A0F);
  SCE_NET_APCTL_ERROR_BUSY = Cardinal($80410A80);
  SCE_NET_APCTL_ERROR_INVALID_ID = Cardinal($80410A82);
  SCE_UTILITY_ERROR_NETCONF_NO_PROFILE = Cardinal($80110601);
  SCE_UTILITY_ERROR_NETCONF_BAD_PROFILE = Cardinal($80110602);
  SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED = Cardinal($8002013A);
  SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER = Cardinal($80410402);
  SCE_NET_RESOLVER_ERROR_INVALID_PTR = Cardinal($80410403);
  SCE_NET_RESOLVER_ERROR_INVALID_BUFLEN = Cardinal($80410404);
  SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND = Cardinal($80410408);
  SCE_NET_RESOLVER_ERROR_BUSY = Cardinal($80410409);
  SCE_NET_RESOLVER_ERROR_NOT_RUNNING = Cardinal($8041040A);
  SCE_NET_RESOLVER_ERROR_EMPTY_NAME = Cardinal($80410418);
  SCE_NET_RESOLVER_ERROR_INVALID_STATUS_PTR = Cardinal($80410419);
  SCE_NET_RESOLVER_ERROR_NO_ASYNC = Cardinal($8041041A);
  SCE_KERNEL_ERROR_ALREADY = Cardinal($80000020);
  SCE_HTTP_ERROR_NO_RESPONSE = Cardinal($80431065);
  SCE_HTTP_ERROR_INVALID_ID = Cardinal($80431100);
  ApctlStateDisconnected = 0;
  ApctlStateScanning = 1;
  ApctlEventScanRequest = 1;
  ApctlEventScanComplete = 2;
  // How long a scan of every channel takes.
  ApctlScanNs = 1450000000;
  // Within the bounds the firmware keeps, as hardware reports them.
  NetPoolReserved = $20;
  NetPoolPeak = $3A00;
  NetPoolUsed = $2E40;

// sceParseUri. sceUriParse splits a URI into scheme, user, password, host,
// path, query and fragment, copied one after the other (each NUL-ended)
// into the caller's work area. The scheme is what comes before the first
// ':' when it is made of scheme characters; "//" after it marks an
// authority, but the part after a scheme is read as user@host:port either
// way, as long as it starts with a host character (letters, digits, '-',
// '.'). With no scheme the whole string is that part. Ports take at most
// five digits and up to 65536, which wraps to 0; none given means the
// scheme's.

const
  SCE_HTTP_ERROR_INVALID_VALUE = Cardinal($80433060);
  SCE_HTTP_ERROR_OUT_OF_SIZE = Cardinal($80433022);
  SCE_HTTP_ERROR_INVALID_ARGS = Cardinal($804331FE);

type
  TParsedUri = record
    NoSlash: Boolean;
    Parts: array[0..6] of RawByteString;
    Port: Cardinal;
  end;

function UriSchemeChar(C: AnsiChar): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']);
end;

function UriHostChar(C: AnsiChar): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '.']);
end;

function UriDefaultPort(const Scheme: RawByteString): Cardinal;
begin
  var S := LowerCase(string(Scheme));
  if S = 'http' then
    Result := 80
  else if S = 'https' then
    Result := 443
  else
    Result := 0;
end;

function ParseUriText(const S: RawByteString; out U: TParsedUri): Boolean;
begin
  Result := False;
  U := Default(TParsedUri);
  var N := Length(S);
  var P := 1;
  var I := 1;
  while (I <= N) and UriSchemeChar(S[I]) do
    Inc(I);
  if (I <= N) and (S[I] = ':') then
  begin
    U.Parts[0] := Copy(S, 1, I - 1);
    P := I + 1;
  end;
  U.NoSlash := True;
  if (U.Parts[0] <> '') and (P + 1 <= N) and (S[P] = '/') and (S[P + 1] = '/') then
  begin
    U.NoSlash := False;
    Inc(P, 2);
  end;
  // User information runs to an '@' before the path.
  var J := P;
  while (J <= N) and not CharInSet(S[J], ['/', '?', '#', '@']) do
    Inc(J);
  if (J <= N) and (S[J] = '@') then
  begin
    var Info := Copy(S, P, J - P);
    var Colon := Pos(AnsiChar(':'), Info);
    if Colon > 0 then
    begin
      U.Parts[1] := Copy(Info, 1, Colon - 1);
      U.Parts[2] := Copy(Info, Colon + 1, MaxInt);
    end
    else
      U.Parts[1] := Info;
    P := J + 1;
  end;
  U.Port := UriDefaultPort(U.Parts[0]);
  if (P <= N) and UriHostChar(S[P]) then
  begin
    var H := P;
    while (P <= N) and UriHostChar(S[P]) do
      Inc(P);
    U.Parts[3] := Copy(S, H, P - H);
    if (P <= N) and (S[P] = ':') then
    begin
      Inc(P);
      var D := P;
      while (P <= N) and CharInSet(S[P], ['0'..'9']) do
        Inc(P);
      var Digits := P - D;
      if Digits = 0 then
      begin
        if (P <= N) and not CharInSet(S[P], ['/', '?', '#']) then
          Exit;
      end
      else
      begin
        if Digits > 5 then
          Exit;
        var V := StrToInt(string(Copy(S, D, Digits)));
        if V > 65536 then
          Exit;
        U.Port := Cardinal(V) and $FFFF;
      end;
    end;
  end;
  var Q := P;
  while (Q <= N) and not CharInSet(S[Q], ['?', '#']) do
    Inc(Q);
  U.Parts[4] := Copy(S, P, Q - P);
  P := Q;
  if (P <= N) and (S[P] = '?') then
  begin
    while (Q <= N) and (S[Q] <> '#') do
      Inc(Q);
    U.Parts[5] := Copy(S, P, Q - P);
    P := Q;
  end;
  if P <= N then
    U.Parts[6] := Copy(S, P, MaxInt);
  Result := True;
end;

procedure TPSPNet.hUriParse;
begin
  var Parsed := FHLE.Arg(0);
  var UriPtr := FHLE.Arg(1);
  var Work := FHLE.Arg(2);
  var SizePtr := FHLE.Arg(3);
  var WorkLen := FHLE.ArgInt(4);
  if UriPtr = 0 then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_VALUE);
    Exit;
  end;
  var U: TParsedUri;
  if not ParseUriText(FMemory.ReadAnsi(UriPtr, 4096), U) then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_VALUE);
    Exit;
  end;
  var Need := 0;
  for var K := 0 to 6 do
    Inc(Need, Length(U.Parts[K]) + 1);
  if (Parsed = 0) or (Work = 0) then
  begin
    // The size query.
    if SizePtr = 0 then
      FHLE.Result(SCE_HTTP_ERROR_INVALID_ARGS)
    else
    begin
      FMemory.Write32(SizePtr, Cardinal(Need));
      FHLE.Result(0);
    end;
    Exit;
  end;
  if Need > WorkLen then
  begin
    FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
    Exit;
  end;
  FMemory.Fill(Parsed, 0, 44);
  FMemory.Write32(Parsed, Ord(U.NoSlash));
  var At := Work;
  for var K := 0 to 6 do
  begin
    FMemory.WriteString(At, U.Parts[K], Length(U.Parts[K]) + 1);
    FMemory.Write32(Parsed + 4 + Cardinal(K * 4), At);
    Inc(At, Length(U.Parts[K]) + 1);
  end;
  FMemory.Write16(Parsed + 32, U.Port);
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, Cardinal(Need));
  FHLE.Result(0);
end;

procedure TPSPNet.hUriBuild;
const
  WithScheme = $01;
  WithHost = $02;
  WithPort = $04;
  WithPath = $08;
  WithUser = $10;
  WithPassword = $20;
  WithQuery = $40;
  WithFragment = $80;
begin
  var Out_ := FHLE.Arg(0);
  var SizePtr := FHLE.Arg(1);
  var OutLen := FHLE.ArgInt(2);
  var Parsed := FHLE.Arg(3);
  var Flags := FHLE.Arg(4);
  if Parsed = 0 then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ARGS);
    Exit;
  end;
  var Part: array[0..6] of RawByteString;
  for var K := 0 to 6 do
    Part[K] := FMemory.ReadAnsi(FMemory.Read32(Parsed + 4 + Cardinal(K * 4)), 4096);
  var NoSlash := FMemory.Read32(Parsed) <> 0;
  var Port := FMemory.Read16(Parsed + 32);
  var S: RawByteString := '';
  if (Flags and WithScheme) <> 0 then
  begin
    S := Part[0] + ':';
    if not NoSlash then
      S := S + '//';
  end;
  if ((Flags and WithUser) <> 0) and (Part[1] <> '') then
  begin
    S := S + Part[1];
    if ((Flags and WithPassword) <> 0) and (Part[2] <> '') then
      S := S + ':' + Part[2];
    S := S + '@';
  end;
  if (Flags and WithHost) <> 0 then
    S := S + Part[3];
  if ((Flags and WithPort) <> 0) and (Port <> UriDefaultPort(Part[0])) then
    S := S + ':' + RawByteString(IntToStr(Port));
  if (Flags and WithPath) <> 0 then
    S := S + Part[4];
  if (Flags and WithQuery) <> 0 then
    S := S + Part[5];
  if (Flags and WithFragment) <> 0 then
    S := S + Part[6];
  var Need := Length(S) + 1;
  if Out_ <> 0 then
  begin
    if Need > OutLen then
    begin
      FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
      Exit;
    end;
    FMemory.WriteString(Out_, S, Need);
  end;
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, Cardinal(Need));
  FHLE.Result(0);
end;

// Characters left alone: letters, digits and - _ . *; the rest become %XX.
function UriSafe(C: Byte): Boolean;
begin
  Result := CharInSet(AnsiChar(C), ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '*']);
end;

procedure TPSPNet.hUriEscape;
const
  Hex: array[0..15] of AnsiChar = '0123456789ABCDEF';
begin
  var Out_ := FHLE.Arg(0);
  var LenPtr := FHLE.Arg(1);
  var OutLen := FHLE.ArgInt(2);
  var Src := FMemory.ReadAnsi(FHLE.Arg(3), 65536);
  var S: RawByteString := '';
  for var I := 1 to Length(Src) do
  begin
    var C := Ord(Src[I]);
    if UriSafe(C) then
      S := S + Src[I]
    else
      S := S + '%' + Hex[C shr 4] + Hex[C and 15];
  end;
  if Out_ <> 0 then
  begin
    // Written as far as it fits.
    for var I := 1 to Length(S) do
    begin
      if I > OutLen then
      begin
        FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
        Exit;
      end;
      FMemory.Write8(Out_ + Cardinal(I - 1), Ord(S[I]));
    end;
    if Length(S) >= OutLen then
    begin
      FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
      Exit;
    end;
    FMemory.Write8(Out_ + Cardinal(Length(S)), 0);
  end;
  FMemory.Write32(LenPtr, Cardinal(Length(S) + 1));
  FHLE.Result(0);
end;

function HexValue(C: AnsiChar): Integer;
begin
  case C of
    '0'..'9':
      Result := Ord(C) - Ord('0');
    'A'..'F':
      Result := Ord(C) - Ord('A') + 10;
    'a'..'f':
      Result := Ord(C) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

procedure TPSPNet.hUriUnescape;
begin
  // Returns the source length plus two for each escape.
  var Out_ := FHLE.Arg(0);
  var LenPtr := FHLE.Arg(1);
  var OutLen := FHLE.ArgInt(2);
  var Src := FMemory.ReadAnsi(FHLE.Arg(3), 65536);
  var Count := 0;
  var Escapes := 0;
  var I := 1;
  while I <= Length(Src) do
  begin
    var C := Ord(Src[I]);
    if Src[I] = '%' then
    begin
      if (I + 2 > Length(Src)) or (HexValue(Src[I + 1]) < 0) or (HexValue(Src[I + 2]) < 0) then
      begin
        FHLE.Result(SCE_HTTP_ERROR_INVALID_VALUE);
        Exit;
      end;
      C := HexValue(Src[I + 1]) * 16 + HexValue(Src[I + 2]);
      Inc(I, 3);
      Inc(Escapes);
    end
    else
      Inc(I);
    if Out_ <> 0 then
    begin
      if Count >= OutLen then
      begin
        FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
        Exit;
      end;
      FMemory.Write8(Out_ + Cardinal(Count), C);
    end;
    Inc(Count);
  end;
  if Out_ <> 0 then
  begin
    if Count >= OutLen then
    begin
      FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
      Exit;
    end;
    FMemory.Write8(Out_ + Cardinal(Count), 0);
  end;
  FMemory.Write32(LenPtr, Cardinal(Count + 1));
  FHLE.Result(Cardinal(Length(Src) + 2 * Escapes));
end;

// sceNetInet: a BSD stack with only its loopback interface up. Segments and
// datagrams take a moment to cross it, and a TCP send buffer drains into
// the peer's receive buffer as that has room. errno is per thread and
// cleared by every call that succeeds.

const
  EINTR = 4;
  EBADF = 9;
  EAGAIN = 11;
  EINVAL = 22;
  EMFILE = 24;
  ENOSPC = 28;
  EPIPE = 32;
  EOPNOTSUPP = 95;
  ECONNRESET = 104;
  ENOBUFS = 105;
  EAFNOSUPPORT = 106;
  ENOPROTOOPT = 109;
  ECONNREFUSED = 111;
  EADDRINUSE = 112;
  EHOSTUNREACH = 118;
  EINPROGRESS = 119;
  EALREADY = 120;
  EDESTADDRREQ = 121;
  EMSGSIZE = 122;
  EPROTONOSUPPORT = 123;
  EADDRNOTAVAIL = 125;
  EISCONN = 127;
  ENOTCONN = 128;
  INET_AF_INET = 2;
  INET_LOOPBACK = $7F000001;
  INET_MSG_PEEK = $2;
  INET_MSG_TRUNC = $10;
  INET_MSG_WAITALL = $40;
  INET_MSG_DONTWAIT = $80;
  SO_LINGER = $80;
  // The stack's descriptors run 1..255.
  InetMaxFd = 255;
  // Loopback delivery.
  InetLatencyNs = 100000;
  InetTickNs = 10000000;
  // The largest buffer the stack reserves.
  InetMaxBuffer = 262144 * 2048 div 2176;

{ TInetSocket }

constructor TInetSocket.Create(AKind: Integer);
begin
  inherited Create;
  Kind := AKind;
  Datagrams := TQueue<TInetDatagram>.Create;
  AcceptQueue := TList<TInetSocket>.Create;
  SynQueue := TList<TInetSocket>.Create;
  if Kind = 1 then
  begin
    SndBuf := $4000;
    RcvBuf := $4000;
  end
  else
  begin
    SndBuf := $2400;
    RcvBuf := $A280;
  end;
  SndLowat := $800;
  RcvLowat := 1;
  TTL := 64;
end;

destructor TInetSocket.Destroy;
begin
  Datagrams.Free;
  AcceptQueue.Free;
  SynQueue.Free;
  inherited;
end;

{ State }

procedure TPSPNet.InetReset;
begin
  FWaiters.Clear;
  FSockets.Clear;
  for var S in FPcbs do
    if not FDeadPcbs.Contains(S) then
      FDeadPcbs.Add(S);
  FPcbs.Clear;
  FDeadPcbs.Clear;
  FErrno.Clear;
  FInetInited := False;
  FNextFd := 1;
  FNextEphemeral := 1024;
end;

procedure TPSPNet.SetErrnoOf(T: TPSPThread; Err: Integer);
begin
  if T <> nil then
    FErrno.AddOrSetValue(T.UID, Err);
end;

procedure TPSPNet.InetFail(Err: Integer);
begin
  SetErrnoOf(FKernel.Current, Err);
  FHLE.Result(Cardinal(-1));
end;

procedure TPSPNet.InetOk(Value: Integer);
begin
  SetErrnoOf(FKernel.Current, 0);
  FHLE.Result(Cardinal(Value));
end;

function TPSPNet.SockOf(Fd: Integer): TInetSocket;
begin
  if not FSockets.TryGetValue(Fd, Result) then
    Result := nil;
end;

function TPSPNet.NewFd: Integer;
begin
  // Handed out round, after the last one given.
  for var K := 0 to InetMaxFd - 1 do
  begin
    var Fd := (FNextFd - 1 + K) mod InetMaxFd + 1;
    if not FSockets.ContainsKey(Fd) then
    begin
      FNextFd := Fd mod InetMaxFd + 1;
      Exit(Fd);
    end;
  end;
  Result := -1;
end;

function TPSPNet.NewSock(Kind: Integer): TInetSocket;
begin
  Result := TInetSocket.Create(Kind);
  // The stack keeps its control blocks newest first.
  FPcbs.Insert(0, Result);
end;

procedure TPSPNet.DropPcb(S: TInetSocket);
begin
  if S.Fd > 0 then
    FSockets.Remove(S.Fd);
  for var W in FWaiters.ToArray do
    if W.Sock = S then
      W.Sock := nil;
  if FPcbs.Remove(S) >= 0 then
    FDeadPcbs.Add(S);
end;

function TPSPNet.EphemeralPort(Kind: Integer): Integer;
begin
  repeat
    Inc(FNextEphemeral);
    if FNextEphemeral > 5000 then
      FNextEphemeral := 1025;
  until not PortInUse(Kind, 0, FNextEphemeral, nil);
  Result := FNextEphemeral;
end;

function TPSPNet.PortInUse(Kind: Integer; IP: Cardinal; Port: Integer; Self_: TInetSocket): Boolean;
begin
  for var S in FPcbs do
    if (S <> Self_) and (S.Kind = Kind) and S.Bound and (S.LocalPort = Port) and ((S.LocalIP = 0) or (IP = 0) or
      (S.LocalIP = IP)) and not (S.Closed and (S.State = isClosed)) then
      Exit(True);
  Result := False;
end;

function TPSPNet.ReadAddr(Addr: Cardinal; out IP: Cardinal; out Port: Integer): Boolean;
begin
  Result := FMemory.Read8(Addr + 1) = INET_AF_INET;
  Port := Integer((FMemory.Read8(Addr + 2) shl 8) or FMemory.Read8(Addr + 3));
  IP := (FMemory.Read8(Addr + 4) shl 24) or (FMemory.Read8(Addr + 5) shl 16) or (FMemory.Read8(Addr + 6) shl 8) or
    FMemory.Read8(Addr + 7);
end;

procedure TPSPNet.WriteAddr(Addr, LenPtr: Cardinal; IP: Cardinal; Port: Integer);
begin
  // As much of the address as the length allows.
  if (Addr = 0) or (LenPtr = 0) then
    Exit;
  var Bytes: array[0..15] of Byte;
  FillChar(Bytes, SizeOf(Bytes), 0);
  Bytes[0] := 16;
  Bytes[1] := INET_AF_INET;
  Bytes[2] := Port shr 8;
  Bytes[3] := Port and $FF;
  Bytes[4] := IP shr 24;
  Bytes[5] := (IP shr 16) and $FF;
  Bytes[6] := (IP shr 8) and $FF;
  Bytes[7] := IP and $FF;
  var N := Integer(FMemory.Read32(LenPtr));
  if N < 0 then
    N := 0;
  if N > 16 then
    N := 16;
  if N > 0 then
    FMemory.WriteBytes(Addr, Bytes[0], N);
  FMemory.Write32(LenPtr, Cardinal(N));
end;

procedure TPSPNet.Later(const Event: IPSPStateAction);
begin
  FKernel.AddStateTimer(FKernel.Scheduler.Now + InetLatencyNs, Self,
    TPSPStateAction.Create(StateLater, [], [], '', Event));
end;

procedure TPSPNet.StateLater(Action: TPSPStateAction; Value: Cardinal);
begin
  Action.Next.Run;
  InetWake;
end;

function TPSPNet.NewAttempt(const Kind: string; const Objects: array of TObject; const Args: array of Int64): TInetAttempt;
begin
  Result := TPSPStateAction.Create(StateAttempt, Objects, Args, Kind);
end;

function TPSPNet.TryAttempt(const Work: TInetAttempt; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  Work.Run(Ord(Final));
  var A := TPSPStateAction(Work as TObject);
  if Length(A.Results) <> 3 then
    raise EReadError.Create('Invalid socket operation result');
  Ret := Integer(A.Results[1]);
  Err := Integer(A.Results[2]);
  Result := A.Results[0] <> 0;
end;

procedure TPSPNet.StateAttempt(Action: TPSPStateAction; Value: Cardinal);
begin
  var Ret: Integer := 0;
  var Err: Integer := 0;
  var Done := True;
  var Final := Value <> 0;
  if Action.Text = 'error' then
  begin
    Ret := -1;
    Err := Integer(Action.Arg(0));
  end
  else if Action.Text = 'delay' then
    Done := Final
  else if Action.Text = 'send' then
    Done := TrySend(Action, Final, Ret, Err)
  else if Action.Text = 'recv-datagram' then
    Done := TryRecvDatagram(Action, Final, Ret, Err)
  else if Action.Text = 'recv-stream' then
    Done := TryRecvStream(Action, Final, Ret, Err)
  else if Action.Text = 'accept' then
    Done := TryAccept(Action, Final, Ret, Err)
  else if Action.Text = 'connect' then
    Done := TryConnect(Action, Final, Ret, Err)
  else if Action.Text = 'select' then
    Done := TrySelect(Action, Final, Ret, Err)
  else if Action.Text = 'poll' then
    Done := TryPoll(Action, Final, Ret, Err)
  else if Action.Text = 'pdp-recv' then
    Done := TryPdpRecv(Action, Final, Ret, Err)
  else if Action.Text = 'ptp-connect' then
    Done := TryPtpConnect(Action, Final, Ret, Err)
  else if Action.Text = 'ptp-accept' then
    Done := TryPtpAccept(Action, Final, Ret, Err)
  else if Action.Text = 'ptp-recv' then
    Done := TryPtpRecv(Action, Final, Ret, Err)
  else if Action.Text = 'adhoc-poll' then
    Done := TryAdhocPoll(Action, Final, Ret, Err)
  else
    raise EReadError.Create('Invalid socket state operation');
  Action.Results := [Cardinal(Ord(Done)), Cardinal(Ret), Cardinal(Err)];
end;

{ Blocking }

procedure TPSPNet.FinishWaiter(W: TInetWaiter; Final: Boolean);
begin
  var Ret, Err: Integer;
  if not TryAttempt(W.Attempt, Final, Ret, Err) then
    Exit;
  var T := W.Thread;
  if W.Timer <> 0 then
    FKernel.CancelTimer(W.Timer);
  FWaiters.Remove(W);
  SetErrnoOf(T, Err);
  if T.IsWaiting and (T.Wait.HLETag = 'inet') then
    FKernel.EndWait(T, Cardinal(Ret));
end;

procedure TPSPNet.InetWake;
begin
  for var W in FWaiters.ToArray do
    if FWaiters.Contains(W) then
      FinishWaiter(W, False);
end;

procedure TPSPNet.InetWaitAbort(T: TPSPThread);
begin
  for var W in FWaiters.ToArray do
    if W.Thread = T then
    begin
      if W.Timer <> 0 then
        FKernel.CancelTimer(W.Timer);
      FWaiters.Remove(W);
    end;
end;

procedure TPSPNet.InetAbortThread(T: TPSPThread);
begin
  for var W in FWaiters.ToArray do
    if W.Thread = T then
    begin
      W.Attempt := NewAttempt('error', [], [EINTR]);
      FinishWaiter(W, True);
    end;
end;

procedure TPSPNet.Run(S: TInetSocket; TimeoutNs: Int64; NonBlocking: Boolean; const Attempt: TInetAttempt);
begin
  // Done at once if it can be; otherwise EAGAIN for a non-blocking call, or
  // the thread waits for the stack (until the timeout, when there is one).
  var Ret, Err: Integer;
  if TryAttempt(Attempt, NonBlocking or not FKernel.CanWait, Ret, Err) then
  begin
    SetErrnoOf(FKernel.Current, Err);
    FHLE.Result(Cardinal(Ret));
    Exit;
  end;
  var W := TInetWaiter.Create;
  W.Thread := FKernel.Current;
  W.Sock := S;
  W.Attempt := Attempt;
  FWaiters.Add(W);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, InetWaitAbort, 'inet');
  if TimeoutNs > 0 then
    W.Timer := FKernel.AddStateTimer(FKernel.Scheduler.Now + TimeoutNs, W.Thread,
      TPSPStateAction.Create(StateWaitTimeout, [W], []));
end;

procedure TPSPNet.StateWaitTimeout(Action: TPSPStateAction; Value: Cardinal);
begin
  var W := TInetWaiter(Action.Obj(0));
  if FWaiters.Contains(W) then
  begin
    W.Timer := 0;
    FinishWaiter(W, True);
  end;
end;

{ Streams }

procedure TPSPNet.ScheduleTransfer(S: TInetSocket);
begin
  if S.TransferScheduled then
    Exit;
  S.TransferScheduled := True;
  Later(TPSPStateAction.Create(StateSocketEvent, [S], [], 'transfer'));
end;

procedure TPSPNet.StateSocketEvent(Action: TPSPStateAction; Value: Cardinal);
begin
  var S := TInetSocket(Action.Obj(0));
  if Action.Text = 'transfer' then
  begin
    S.TransferScheduled := False;
    Transfer(S);
  end
  else if Action.Text = 'reset' then
    PeerReset(S)
  else if Action.Text = 'handshake' then
    Handshake(S)
  else
    raise EReadError.Create('Invalid delayed socket event');
end;

procedure TPSPNet.StateSynRetry(Action: TPSPStateAction; Value: Cardinal);
begin
  var S := TInetSocket(Action.Obj(0));
  if FPcbs.Contains(S) then
    Handshake(S);
  InetWake;
end;

procedure TPSPNet.PeerReset(S: TInetSocket);
begin
  // An RST: after the peer's FIN it reads as a broken pipe.
  if S.FinReceived then
    S.SoError := EPIPE
  else
    S.SoError := ECONNRESET;
  S.State := isClosed;
  S.CantRecvMore := True;
  S.CantSendMore := True;
  S.RecvLen := 0;
  S.SendLen := 0;
  S.FinPending := False;
  S.Peer := nil;
  if S.Closed then
    DropPcb(S);
end;

procedure TPSPNet.Transfer(S: TInetSocket);
begin
  var P := S.Peer;
  if (S.State <> isEstablished) or (P = nil) then
    Exit;
  if P.Closed and (S.SendLen > 0) then
  begin
    // Data for a socket that is gone: it answers with an RST.
    S.SendLen := 0;
    Later(TPSPStateAction.Create(StateSocketEvent, [S], [], 'reset'));
    P.Peer := nil;
    DropPcb(P);
    Exit;
  end;
  if S.SendLen > 0 then
  begin
    var N := S.SendLen;
    if not P.ReadShut then
      N := Min(N, P.RcvBuf - P.RecvLen);
    if N > 0 then
    begin
      if not P.ReadShut then
      begin
        if Length(P.RecvData) < P.RecvLen + N then
          SetLength(P.RecvData, P.RecvLen + N);
        Move(S.SendData[0], P.RecvData[P.RecvLen], N);
        Inc(P.RecvLen, N);
      end;
      Move(S.SendData[N], S.SendData[0], S.SendLen - N);
      Dec(S.SendLen, N);
    end;
  end;
  if (S.SendLen = 0) and S.FinPending then
  begin
    S.FinPending := False;
    P.FinReceived := True;
    P.CantRecvMore := True;
    if P.Closed and S.Closed then
    begin
      DropPcb(P);
      DropPcb(S);
    end;
  end;
end;

function TPSPNet.FindListener(IP: Cardinal; Port: Integer): TInetSocket;
begin
  for var S in FPcbs do
    if (S.Kind = 1) and (S.State = isListening) and not S.Closed and (S.LocalPort = Port) and ((S.LocalIP = 0) or
      (S.LocalIP = IP)) then
      Exit(S);
  Result := nil;
end;

function TPSPNet.QueueRoom(L: TInetSocket): Boolean;
begin
  Result := L.AcceptQueue.Count < (3 * Max(L.Backlog, 0)) div 2 + 1;
end;

procedure TPSPNet.Establish(L, C: TInetSocket);
begin
  var N := NewSock(1);
  N.Bound := True;
  N.LocalIP := C.PeerIP;
  N.LocalPort := C.PeerPort;
  N.PeerIP := C.LocalIP;
  N.PeerPort := C.LocalPort;
  N.HasPeer := True;
  N.Options := L.Options and not Cardinal($2);
  N.SndBuf := L.SndBuf;
  N.RcvBuf := L.RcvBuf;
  N.NBIO := L.NBIO;
  N.NoDelay := L.NoDelay;
  N.State := isEstablished;
  N.Peer := C;
  C.Peer := N;
  C.State := isEstablished;
  L.AcceptQueue.Add(N);
end;

procedure TPSPNet.Handshake(C: TInetSocket);
begin
  if C.State <> isConnecting then
    Exit;
  var L := FindListener(C.PeerIP, C.PeerPort);
  if L = nil then
  begin
    C.State := isClosed;
    C.ConnectFailed := True;
    C.SoError := ECONNREFUSED;
    if C.Closed then
      DropPcb(C);
  end
  else if QueueRoom(L) then
    Establish(L, C)
  else if not L.SynQueue.Contains(C) then
    // Dropped for now; the retransmission gets in when there is room.
    L.SynQueue.Add(C);
end;

procedure TPSPNet.CloseSocket(S: TInetSocket; Reset: Boolean);
begin
  S.Closed := True;
  FSockets.Remove(S.Fd);
  S.Fd := 0;
  // Threads blocked on it give up.
  for var W in FWaiters.ToArray do
    if W.Sock = S then
    begin
      W.Attempt := NewAttempt('error', [], [EBADF]);
      FinishWaiter(W, True);
    end;
  if S.Kind <> 1 then
  begin
    DropPcb(S);
    Exit;
  end;
  case S.State of
    isListening:
      begin
        for var N in S.AcceptQueue.ToArray do
        begin
          var C := N.Peer;
          N.Closed := True;
          DropPcb(N);
          if C <> nil then
            Later(TPSPStateAction.Create(StateSocketEvent, [C], [], 'reset'));
        end;
        for var C in S.SynQueue.ToArray do
          Later(TPSPStateAction.Create(StateSocketEvent, [C], [], 'handshake'));
        S.AcceptQueue.Clear;
        S.SynQueue.Clear;
        S.State := isClosed;
        DropPcb(S);
      end;
    isEstablished:
      begin
        var P := S.Peer;
        if Reset or (((S.Options and SO_LINGER) <> 0) and (S.LingerTime = 0)) then
        begin
          S.Peer := nil;
          DropPcb(S);
          if P <> nil then
          begin
            P.Peer := nil;
            Later(TPSPStateAction.Create(StateSocketEvent, [P], [], 'reset'));
          end;
        end
        else
        begin
          S.FinPending := True;
          S.CantRecvMore := True;
          S.CantSendMore := True;
          ScheduleTransfer(S);
        end;
      end;
  else
    begin
      for var L in FPcbs do
        L.SynQueue.Remove(S);
      DropPcb(S);
    end;
  end;
end;

function TPSPNet.Readable(S: TInetSocket): Boolean;
begin
  if S.SoError <> 0 then
    Exit(True);
  if S.Kind = 1 then
    case S.State of
      isListening:
        Result := S.AcceptQueue.Count > 0;
      isEstablished:
        Result := (S.RecvLen >= S.RcvLowat) or S.CantRecvMore;
    else
      Result := S.CantRecvMore;
    end
  else
    Result := (S.Datagrams.Count > 0) or S.ReadShut;
end;

function TPSPNet.Writable(S: TInetSocket): Boolean;
begin
  if S.SoError <> 0 then
    Exit(True);
  if S.Kind = 1 then
    case S.State of
      isEstablished:
        Result := S.CantSendMore or (S.SndBuf - S.SendLen >= S.SndLowat);
      isConnecting, isListening:
        Result := False;
    else
      Result := S.ConnectFailed or S.CantSendMore;
    end
  else
    Result := True;
end;

{ Sending and receiving }

procedure TPSPNet.DeliverDatagram(S: TInetSocket; const Data: TBytes; ToIP: Cardinal; ToPort: Integer);
begin
  var FromIP := S.LocalIP;
  if FromIP = 0 then
    FromIP := INET_LOOPBACK;
  var FromPort := S.LocalPort;
  var Connected := S.HasPeer;
  var A := TPSPStateAction.Create(StateDatagram, [S], [ToIP, ToPort, FromIP, FromPort, Ord(Connected)]);
  A.Data := Data;
  Later(A);
end;

procedure TPSPNet.StateDatagram(Action: TPSPStateAction; Value: Cardinal);
begin
  var S := TInetSocket(Action.Obj(0));
  var ToIP := Cardinal(Action.Arg(0));
  var ToPort := Integer(Action.Arg(1));
  var FromIP := Cardinal(Action.Arg(2));
  var FromPort := Integer(Action.Arg(3));
  var R: TInetSocket := nil;
  for var X in FPcbs do
    if (X.Kind = 2) and not X.Closed and X.Bound and (X.LocalPort = ToPort) and ((X.LocalIP = 0) or
      (X.LocalIP = ToIP) or (ToIP = 0)) then
    begin
      if X.HasPeer and ((X.PeerIP <> FromIP) or (X.PeerPort <> FromPort)) then
        Continue;
      R := X;
      Break;
    end;
  if R = nil then
  begin
    if (Action.Arg(4) <> 0) and FPcbs.Contains(S) then
      S.SoError := ECONNREFUSED;
    Exit;
  end;
  if R.ReadShut or (R.QueuedBytes + Length(Action.Data) > R.RcvBuf) then
    Exit;
  var D: TInetDatagram;
  D.Data := Action.Data;
  D.FromIP := FromIP;
  D.FromPort := FromPort;
  R.Datagrams.Enqueue(D);
  Inc(R.QueuedBytes, Length(D.Data));
end;

procedure TPSPNet.SendCall(Fd: Integer; const Data: TBytes; Flags: Integer; HasTo: Boolean; ToIP: Cardinal; ToPort: Integer);
begin
  var S := SockOf(Fd);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Len := Length(Data);
  if S.Kind <> 1 then
  begin
    if S.WriteShut then
    begin
      InetFail(EPIPE);
      Exit;
    end;
    if S.SoError <> 0 then
    begin
      var E := S.SoError;
      S.SoError := 0;
      InetFail(E);
      Exit;
    end;
    if HasTo and S.HasPeer then
    begin
      InetFail(EISCONN);
      Exit;
    end;
    if not HasTo then
    begin
      if not S.HasPeer then
      begin
        InetFail(EDESTADDRREQ);
        Exit;
      end;
      ToIP := S.PeerIP;
      ToPort := S.PeerPort;
    end;
    if Len > S.SndBuf then
    begin
      InetFail(EMSGSIZE);
      Exit;
    end;
    if (ToIP <> 0) and (ToIP shr 24 <> 127) then
    begin
      InetFail(EHOSTUNREACH);
      Exit;
    end;
    if not S.Bound then
    begin
      S.Bound := True;
      S.LocalIP := 0;
      S.LocalPort := EphemeralPort(S.Kind);
    end;
    if ToIP shr 24 = 127 then
      ToIP := INET_LOOPBACK;
    DeliverDatagram(S, Data, ToIP, ToPort);
    InetOk(Len);
    Exit;
  end;
  // A stream.
  var NonBlocking := S.NBIO or ((Flags and INET_MSG_DONTWAIT) <> 0);
  var Work := NewAttempt('send', [S], [0]);
  TPSPStateAction(Work as TObject).Data := Data;
  Run(S, Int64(S.SndTimeo) * InetTickNs, NonBlocking, Work);
end;

function TPSPNet.TrySend(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TInetSocket(A.Obj(0));
  var Sent := Integer(A.Arg(0));
  var Len := Length(A.Data);
  Result := True;
  Ret := -1;
  if S.CantSendMore or S.WriteShut then
  begin
    Err := EPIPE;
    if S.SoError <> 0 then
    begin
      Err := S.SoError;
      S.SoError := 0;
    end;
    Exit;
  end;
  if S.SoError <> 0 then
  begin
    Err := S.SoError;
    S.SoError := 0;
    Exit;
  end;
  if S.State <> isEstablished then
  begin
    Err := ENOTCONN;
    Exit;
  end;
  var Room := S.SndBuf - S.SendLen;
  var N := Min(Room, Len - Sent);
  if N > 0 then
  begin
    if Length(S.SendData) < S.SendLen + N then
      SetLength(S.SendData, S.SendLen + N);
    Move(A.Data[Sent], S.SendData[S.SendLen], N);
    Inc(S.SendLen, N);
    Inc(Sent, N);
    A.Values[0] := Sent;
    ScheduleTransfer(S);
  end;
  if (Sent = Len) or (Final and (Sent > 0)) then
  begin
    Ret := Sent;
    Err := 0;
  end
  else if Final then
    Err := EAGAIN
  else
    Result := False;
end;

procedure TPSPNet.RecvCall(Fd: Integer; const Segs: TArray<TPair<Cardinal, Integer>>; Flags: Integer; FromPtr, FromLenPtr, MsgFlagsPtr: Cardinal);
begin
  var S := SockOf(Fd);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Len := 0;
  for var P in Segs do
    Inc(Len, P.Value);
  var Peek := (Flags and INET_MSG_PEEK) <> 0;
  var NonBlocking := S.NBIO or ((Flags and INET_MSG_DONTWAIT) <> 0);
  var Kind := 'recv-stream';
  if S.Kind <> 1 then
    Kind := 'recv-datagram';
  var Work := NewAttempt(Kind, [S],
    [Len, Ord(Peek), FromPtr, FromLenPtr, MsgFlagsPtr, Ord((Flags and INET_MSG_WAITALL) <> 0)]);
  var A := TPSPStateAction(Work as TObject);
  SetLength(A.Arrays, 1);
  SetLength(A.Arrays[0], Length(Segs) * 2);
  for var I := 0 to High(Segs) do
  begin
    A.Arrays[0][I * 2] := Segs[I].Key;
    A.Arrays[0][I * 2 + 1] := Cardinal(Segs[I].Value);
  end;
  Run(S, Int64(S.RcvTimeo) * InetTickNs, NonBlocking, Work);
end;

procedure TPSPNet.Scatter(Action: TPSPStateAction; const Src: TBytes; Count: Integer);
begin
  var Done := 0;
  var Segs := Action.Arrays[0];
  for var I := 0 to Length(Segs) div 2 - 1 do
  begin
    if Done >= Count then
      Break;
    var N := Min(Integer(Segs[I * 2 + 1]), Count - Done);
    if N > 0 then
      FMemory.WriteBytes(Segs[I * 2], Src[Done], N);
    Inc(Done, N);
  end;
end;

function TPSPNet.TryRecvDatagram(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TInetSocket(A.Obj(0));
  Result := True;
  Ret := -1;
  if S.SoError <> 0 then
  begin
    Err := S.SoError;
    S.SoError := 0;
    Exit;
  end;
  if S.Datagrams.Count > 0 then
  begin
    var D := S.Datagrams.Peek;
    if A.Arg(1) = 0 then
    begin
      S.Datagrams.Dequeue;
      Dec(S.QueuedBytes, Length(D.Data));
    end;
    var N := Min(Integer(A.Arg(0)), Length(D.Data));
    Scatter(A, D.Data, N);
    WriteAddr(Cardinal(A.Arg(2)), Cardinal(A.Arg(3)), D.FromIP, D.FromPort);
    if A.Arg(4) <> 0 then
      if N < Length(D.Data) then
        FMemory.Write32(Cardinal(A.Arg(4)), INET_MSG_TRUNC)
      else
        FMemory.Write32(Cardinal(A.Arg(4)), 0);
    Ret := N;
    Err := 0;
    Exit;
  end;
  if S.ReadShut then
  begin
    Ret := 0;
    Err := 0;
    Exit;
  end;
  if Final then
    Err := EAGAIN
  else
    Result := False;
end;

function TPSPNet.TryRecvStream(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TInetSocket(A.Obj(0));
  var Len := Integer(A.Arg(0));
  Result := True;
  Ret := -1;
  if S.SoError <> 0 then
  begin
    Err := S.SoError;
    S.SoError := 0;
    Exit;
  end;
  if (S.State in [isClosed, isListening, isConnecting]) and not S.CantRecvMore then
  begin
    Err := ENOTCONN;
    Exit;
  end;
  if S.ReadShut then
  begin
    Ret := 0;
    Err := 0;
    Exit;
  end;
  if (S.RecvLen > 0) and ((Len = 0) or (A.Arg(5) = 0) or (S.RecvLen >= Len) or S.CantRecvMore) then
  begin
    var N := Min(Len, S.RecvLen);
    Scatter(A, S.RecvData, N);
    if (A.Arg(1) = 0) and (N > 0) then
    begin
      Move(S.RecvData[N], S.RecvData[0], S.RecvLen - N);
      Dec(S.RecvLen, N);
      var P := S.Peer;
      if (P <> nil) and (P.SendLen > 0) then
        ScheduleTransfer(P);
    end;
    if A.Arg(4) <> 0 then
      FMemory.Write32(Cardinal(A.Arg(4)), 0);
    Ret := N;
    Err := 0;
    Exit;
  end;
  if S.CantRecvMore or (Len = 0) then
  begin
    Ret := 0;
    Err := 0;
    Exit;
  end;
  if Final then
    Err := EAGAIN
  else
    Result := False;
end;

// The sceNetInet calls.

const
  // A connection the listener had no room for gets in on its SYN's retransmission.
  InetSynRetryNs = 3000000000;
  POLLIN = $1;
  POLLOUT = $4;
  POLLERR = $8;
  POLLHUP = $10;
  POLLNVAL = $20;
  POLLRDNORM = $40;

procedure TPSPNet.hInetInit;
begin
  FInetInited := True;
  FHLE.Result(0);
end;

procedure TPSPNet.hInetTerm;
begin
  for var S in FSockets.Values.ToArray do
    CloseSocket(S, False);
  FInetInited := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hInetSocket;
begin
  var Domain := FHLE.ArgInt(0);
  var Kind := FHLE.ArgInt(1);
  var Protocol := FHLE.ArgInt(2);
  var Ok := Domain = INET_AF_INET;
  case Kind of
    1:
      Ok := Ok and (Protocol in [0, 6]);
    2:
      Ok := Ok and (Protocol in [0, 17]);
    3:
      ;
  else
    Ok := False;
  end;
  if not Ok then
  begin
    InetFail(EPROTONOSUPPORT);
    Exit;
  end;
  var Fd := NewFd;
  if Fd < 0 then
  begin
    InetFail(EMFILE);
    Exit;
  end;
  var S := NewSock(Kind);
  S.Fd := Fd;
  FSockets.Add(Fd, S);
  InetOk(Fd);
end;

procedure TPSPNet.hInetBind;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Addr := FHLE.Arg(1);
  var Len := FHLE.ArgInt(2);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if S.Bound or (Addr = 0) or (Len < 16) then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var IP: Cardinal;
  var Port: Integer;
  // The family is not looked at: an address of another kind is not the console's.
  if not ReadAddr(Addr, IP, Port) or ((IP <> 0) and (IP <> INET_LOOPBACK)) then
  begin
    InetFail(EADDRNOTAVAIL);
    Exit;
  end;
  if Port = 0 then
    Port := EphemeralPort(S.Kind)
  else if ((S.Options and $204) = 0) and PortInUse(S.Kind, IP, Port, S) then
  begin
    InetFail(EADDRINUSE);
    Exit;
  end;
  S.Bound := True;
  S.LocalIP := IP;
  S.LocalPort := Port;
  InetOk(0);
end;

procedure TPSPNet.hInetListen;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if S.Kind <> 1 then
  begin
    InetFail(EOPNOTSUPP);
    Exit;
  end;
  if not S.Bound then
  begin
    S.ListenFailed := True;
    InetFail(EINVAL);
    Exit;
  end;
  if S.State in [isConnecting, isEstablished] then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  S.State := isListening;
  S.Backlog := FHLE.ArgInt(1);
  InetOk(0);
end;

procedure TPSPNet.hInetAccept;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Addr := FHLE.Arg(1);
  var LenPtr := FHLE.Arg(2);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if S.Kind <> 1 then
  begin
    InetFail(EOPNOTSUPP);
    Exit;
  end;
  if S.State <> isListening then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  Run(S, 0, S.NBIO, NewAttempt('accept', [S], [Addr, LenPtr]));
end;

function TPSPNet.TryAccept(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TInetSocket(A.Obj(0));
  Result := True;
  Ret := -1;
  if S.State <> isListening then
  begin
    Err := EINVAL;
    Exit;
  end;
  if S.AcceptQueue.Count = 0 then
  begin
    if Final then
      Err := EAGAIN
    else
      Result := False;
    Exit;
  end;
  var Fd := NewFd;
  if Fd < 0 then
  begin
    Err := EMFILE;
    Exit;
  end;
  var N := S.AcceptQueue[0];
  S.AcceptQueue.Delete(0);
  N.Fd := Fd;
  FSockets.Add(Fd, N);
  WriteAddr(Cardinal(A.Arg(0)), Cardinal(A.Arg(1)), N.PeerIP, N.PeerPort);
  if S.SynQueue.Count > 0 then
  begin
    var C := S.SynQueue[0];
    S.SynQueue.Delete(0);
    FKernel.AddStateTimer(FKernel.Scheduler.Now + InetSynRetryNs, Self, TPSPStateAction.Create(StateSynRetry, [C], []));
  end;
  Ret := Fd;
  Err := 0;
end;

procedure TPSPNet.hInetConnect;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Addr := FHLE.Arg(1);
  var Len := FHLE.ArgInt(2);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if (Addr = 0) or (Len < 16) then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var IP: Cardinal;
  var Port: Integer;
  if not ReadAddr(Addr, IP, Port) then
  begin
    InetFail(EAFNOSUPPORT);
    Exit;
  end;
  if S.Kind = 1 then
  begin
    if (S.State = isListening) or S.ListenFailed or S.ConnectFailed then
    begin
      InetFail(EINVAL);
      Exit;
    end;
    if S.State = isEstablished then
    begin
      InetFail(EISCONN);
      Exit;
    end;
    if S.State = isConnecting then
    begin
      InetFail(EALREADY);
      Exit;
    end;
  end;
  if (IP <> 0) and (IP shr 24 <> 127) then
  begin
    InetFail(EHOSTUNREACH);
    Exit;
  end;
  if not S.Bound then
  begin
    S.Bound := True;
    S.LocalPort := EphemeralPort(S.Kind);
  end;
  if S.LocalIP = 0 then
    S.LocalIP := INET_LOOPBACK;
  S.PeerIP := INET_LOOPBACK;
  S.PeerPort := Port;
  S.HasPeer := True;
  if S.Kind <> 1 then
  begin
    InetOk(0);
    Exit;
  end;
  S.State := isConnecting;
  Later(TPSPStateAction.Create(StateSocketEvent, [S], [], 'handshake'));
  if S.NBIO then
  begin
    InetFail(EINPROGRESS);
    Exit;
  end;
  Run(S, 0, False, NewAttempt('connect', [S], []));
end;

function TPSPNet.TryConnect(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TInetSocket(A.Obj(0));
  Result := True;
  Ret := -1;
  if S.State = isEstablished then
  begin
    Ret := 0;
    Err := 0;
  end
  else if S.State = isConnecting then
  begin
    Err := EAGAIN;
    Result := Final;
  end
  else
  begin
    Err := S.SoError;
    S.SoError := 0;
    if Err = 0 then
      Err := ECONNREFUSED;
  end;
end;

function GuestBytesOf(M: TPSPMemory; Addr: Cardinal; Len: Integer): TBytes;
begin
  SetLength(Result, Max(Len, 0));
  if Len > 0 then
    M.ReadBytes(Addr, Result[0], Len);
end;

procedure TPSPNet.hInetSend;
begin
  if FHLE.ArgInt(2) < 0 then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  SendCall(FHLE.ArgInt(0), GuestBytesOf(FMemory, FHLE.Arg(1), FHLE.ArgInt(2)), FHLE.ArgInt(3), False, 0, 0);
end;

procedure TPSPNet.hInetSendto;
begin
  var Fd := FHLE.ArgInt(0);
  var Len := FHLE.ArgInt(2);
  var ToAddr := FHLE.Arg(4);
  if Len < 0 then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var IP: Cardinal := 0;
  var Port := 0;
  var S := SockOf(Fd);
  var HasTo := (ToAddr <> 0) and (S <> nil) and (S.Kind <> 1);
  if HasTo then
  begin
    if FHLE.ArgInt(5) < 16 then
    begin
      InetFail(EINVAL);
      Exit;
    end;
    if not ReadAddr(ToAddr, IP, Port) then
    begin
      InetFail(EAFNOSUPPORT);
      Exit;
    end;
  end;
  SendCall(Fd, GuestBytesOf(FMemory, FHLE.Arg(1), Len), FHLE.ArgInt(3), HasTo, IP, Port);
end;

procedure TPSPNet.hInetSendmsg;
begin
  var Fd := FHLE.ArgInt(0);
  var Msg := FHLE.Arg(1);
  var S := SockOf(Fd);
  if (S = nil) or (Msg = 0) then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Name := FMemory.Read32(Msg);
  var Iov := FMemory.Read32(Msg + 8);
  var IovLen := Integer(FMemory.Read32(Msg + 12));
  var Data: TBytes := nil;
  for var I := 0 to IovLen - 1 do
    Data := Data + GuestBytesOf(FMemory, FMemory.Read32(Iov + Cardinal(I * 8)), Integer(FMemory.Read32(Iov +
          Cardinal(I * 8) + 4)));
  var IP: Cardinal := 0;
  var Port := 0;
  var HasTo := (Name <> 0) and (S.Kind <> 1);
  if HasTo and not ReadAddr(Name, IP, Port) then
  begin
    InetFail(EAFNOSUPPORT);
    Exit;
  end;
  SendCall(Fd, Data, FHLE.ArgInt(2), HasTo, IP, Port);
end;

procedure TPSPNet.hInetRecv;
begin
  RecvCall(FHLE.ArgInt(0), [TPair<Cardinal, Integer>.Create(FHLE.Arg(1), Max(FHLE.ArgInt(2), 0))], FHLE.ArgInt(3), 0, 0,
    0);
end;

procedure TPSPNet.hInetRecvfrom;
begin
  RecvCall(FHLE.ArgInt(0), [TPair<Cardinal, Integer>.Create(FHLE.Arg(1), Max(FHLE.ArgInt(2), 0))], FHLE.ArgInt(3),
    FHLE.Arg(4), FHLE.Arg(5), 0);
end;

procedure TPSPNet.hInetRecvmsg;
begin
  var Msg := FHLE.Arg(1);
  if (SockOf(FHLE.ArgInt(0)) = nil) or (Msg = 0) then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Iov := FMemory.Read32(Msg + 8);
  var IovLen := Integer(FMemory.Read32(Msg + 12));
  var Segs: TArray<TPair<Cardinal, Integer>> := nil;
  for var I := 0 to IovLen - 1 do
    Segs := Segs + [TPair<Cardinal, Integer>.Create(FMemory.Read32(Iov + Cardinal(I * 8)),
      Integer(FMemory.Read32(Iov + Cardinal(I * 8) + 4)))];
  var Name := FMemory.Read32(Msg);
  var NameLenPtr: Cardinal := 0;
  if Name <> 0 then
    NameLenPtr := Msg + 4;
  RecvCall(FHLE.ArgInt(0), Segs, FHLE.ArgInt(2), Name, NameLenPtr, Msg + 24);
end;

procedure TPSPNet.hInetClose;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  CloseSocket(S, False);
  InetOk(0);
end;

procedure TPSPNet.hInetCloseWithRST;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  CloseSocket(S, True);
  InetOk(0);
end;

procedure TPSPNet.hInetShutdown;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var How := FHLE.ArgInt(1);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if (How < 0) or (How > 2) then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  if How <> 1 then
  begin
    S.ReadShut := True;
    S.CantRecvMore := True;
    S.RecvLen := 0;
    S.Datagrams.Clear;
    S.QueuedBytes := 0;
  end;
  if How <> 0 then
  begin
    S.WriteShut := True;
    if (S.Kind = 1) and (S.State = isEstablished) and not S.CantSendMore then
    begin
      S.CantSendMore := True;
      S.FinPending := True;
      ScheduleTransfer(S);
    end;
  end;
  InetOk(0);
  InetWake;
end;

procedure TPSPNet.hInetGetsockname;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  WriteAddr(FHLE.Arg(1), FHLE.Arg(2), S.LocalIP, S.LocalPort);
  InetOk(0);
end;

procedure TPSPNet.hInetGetpeername;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Connected := S.HasPeer;
  if S.Kind = 1 then
    Connected := Connected and (S.State in [isConnecting, isEstablished]);
  if not Connected then
  begin
    InetFail(ENOTCONN);
    Exit;
  end;
  WriteAddr(FHLE.Arg(1), FHLE.Arg(2), S.PeerIP, S.PeerPort);
  InetOk(0);
end;

procedure TPSPNet.hInetSetsockopt;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Level := FHLE.ArgInt(1);
  var Name := FHLE.ArgInt(2);
  var Val := FHLE.Arg(3);
  var Len := FHLE.ArgInt(4);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var V := 0;
  if Len >= 4 then
    V := Integer(FMemory.Read32(Val));
  case Level of
    $FFFF:
      case Name of
        $1, $4, $8, $10, $20, $100, $200, $80, $1001..$1006, $1009:
          begin
            if (Len < 4) or ((Name = $80) and (Len < 8)) then
            begin
              InetFail(EINVAL);
              Exit;
            end;
            case Name of
              $80:
                begin
                  if V <> 0 then
                    S.Options := S.Options or SO_LINGER
                  else
                    S.Options := S.Options and not Cardinal(SO_LINGER);
                  S.LingerTime := Integer(FMemory.Read32(Val + 4));
                end;
              $1001, $1002:
                begin
                  if V <= 0 then
                  begin
                    InetFail(EINVAL);
                    Exit;
                  end;
                  if V > InetMaxBuffer then
                  begin
                    InetFail(ENOBUFS);
                    Exit;
                  end;
                  if Name = $1001 then
                    S.SndBuf := V
                  else
                    S.RcvBuf := V;
                end;
              $1003:
                S.SndLowat := Max(1, Min(V, S.SndBuf));
              $1004:
                S.RcvLowat := Max(1, Min(V, S.RcvBuf));
              // A count of microseconds, kept in ticks.
                $1005:
                S.SndTimeo := Integer(Cardinal(V) div 10000);
              $1006:
                S.RcvTimeo := Integer(Cardinal(V) div 10000);
              $1009:
                S.NBIO := V <> 0;
            else
              if V <> 0 then
                S.Options := S.Options or Cardinal(Name)
              else
                S.Options := S.Options and not Cardinal(Name);
            end;
          end;
      else
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    0:
      if Name = 4 then
      begin
        if Len < 4 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        S.TTL := V;
      end
      else
      begin
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    6:
      begin
        if S.Kind <> 1 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        if Name <> 1 then
        begin
          InetFail(ENOPROTOOPT);
          Exit;
        end;
        if Len < 4 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        S.NoDelay := V <> 0;
      end;
  else
    InetFail(EINVAL);
    Exit;
  end;
  InetOk(0);
end;

procedure TPSPNet.hInetGetsockopt;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Level := FHLE.ArgInt(1);
  var Name := FHLE.ArgInt(2);
  var Val := FHLE.Arg(3);
  var LenPtr := FHLE.Arg(4);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Words: TArray<Cardinal>;
  case Level of
    $FFFF:
      case Name of
        $1, $4, $8, $10, $20, $100, $200:
          Words := [S.Options and Cardinal(Name)];
        $80:
          Words := [S.Options and SO_LINGER, Cardinal(S.LingerTime)];
        $1001:
          Words := [Cardinal(S.SndBuf)];
        $1002:
          Words := [Cardinal(S.RcvBuf)];
        $1003:
          Words := [Cardinal(S.SndLowat)];
        $1004:
          Words := [Cardinal(S.RcvLowat)];
        $1005:
          Words := [Cardinal(S.SndTimeo)];
        $1006:
          Words := [Cardinal(S.RcvTimeo)];
        $1007:
          begin
            // A pending error reads as the stack's error code for it.
            if S.SoError <> 0 then
              Words := [$80010000 or Cardinal(S.SoError)]
            else
              Words := [0];
            S.SoError := 0;
          end;
        $1008:
          Words := [Cardinal(S.Kind)];
        $1009:
          Words := [Cardinal(Ord(S.NBIO) * $80)];
      else
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    0:
      if Name = 4 then
        Words := [Cardinal(S.TTL)]
      else
      begin
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    6:
      begin
        if S.Kind <> 1 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        if Name <> 1 then
        begin
          InetFail(ENOPROTOOPT);
          Exit;
        end;
        Words := [Cardinal(Ord(S.NoDelay) * 4)];
      end;
  else
    InetFail(EINVAL);
    Exit;
  end;
  var Bytes: TBytes;
  SetLength(Bytes, Length(Words) * 4);
  for var I := 0 to High(Words) do
    PCardinal(@Bytes[I * 4])^ := Words[I];
  var N := 0;
  if LenPtr <> 0 then
    N := EnsureRange(Integer(FMemory.Read32(LenPtr)), 0, Length(Bytes));
  if N > 0 then
    FMemory.WriteBytes(Val, Bytes[0], N);
  if LenPtr <> 0 then
    FMemory.Write32(LenPtr, Cardinal(N));
  InetOk(0);
end;

procedure TPSPNet.hInetSelect;
begin
  var NFds := EnsureRange(FHLE.ArgInt(0), 0, 256);
  var Sets: TArray<Cardinal> := [FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(3)];
  var Tv := FHLE.Arg(4);
  var TimeoutNs: Int64 := 0;
  var Poll := False;
  if Tv <> 0 then
  begin
    var Sec := Integer(FMemory.Read32(Tv));
    var USec := Integer(FMemory.Read32(Tv + 4));
    if (Sec < 0) or (USec < 0) or (USec >= 1000000) then
    begin
      InetFail(EINVAL);
      Exit;
    end;
    TimeoutNs := Int64(Sec) * 1000000000 + Int64(USec) * 1000;
    Poll := TimeoutNs = 0;
  end;
  var Want: array[0..2] of array[0..7] of Cardinal;
  for var K := 0 to 2 do
    for var I := 0 to 7 do
      if Sets[K] <> 0 then
        Want[K][I] := FMemory.Read32(Sets[K] + Cardinal(I * 4))
      else
        Want[K][I] := 0;
  for var Fd := 0 to NFds - 1 do
    for var K := 0 to 2 do
      if ((Want[K][Fd shr 5] shr (Fd and 31)) and 1 <> 0) and (SockOf(Fd) = nil) then
      begin
        InetFail(EBADF);
        Exit;
      end;
  var Work := NewAttempt('select', [], [NFds, Sets[0], Sets[1], Sets[2]]);
  var A := TPSPStateAction(Work as TObject);
  SetLength(A.Arrays, 1);
  SetLength(A.Arrays[0], 24);
  for var K := 0 to 2 do
    for var I := 0 to 7 do
      A.Arrays[0][K * 8 + I] := Want[K][I];
  Run(nil, TimeoutNs, Poll, Work);
end;

function TPSPNet.TrySelect(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var Got: array[0..2, 0..7] of Cardinal;
  FillChar(Got, SizeOf(Got), 0);
  var Count := 0;
  for var Fd := 0 to Integer(A.Arg(0)) - 1 do
    for var K := 0 to 1 do
      if (A.Arrays[0][K * 8 + (Fd shr 5)] shr (Fd and 31)) and 1 <> 0 then
      begin
        var S := SockOf(Fd);
        if (S <> nil) and (((K = 0) and Readable(S)) or ((K = 1) and Writable(S))) then
        begin
          Got[K, Fd shr 5] := Got[K, Fd shr 5] or (Cardinal(1) shl (Fd and 31));
          Inc(Count);
        end;
      end;
  Result := (Count > 0) or Final;
  if not Result then
    Exit;
  for var K := 0 to 2 do
    if A.Arg(K + 1) <> 0 then
      for var I := 0 to 7 do
        FMemory.Write32(Cardinal(A.Arg(K + 1)) + Cardinal(I * 4), Got[K, I]);
  Ret := Count;
  Err := 0;
end;

procedure TPSPNet.hInetPoll;
begin
  var Fds := FHLE.Arg(0);
  var N := Max(FHLE.ArgInt(1), 0);
  var TimeoutMs := FHLE.ArgInt(2);
  var TimeoutNs: Int64 := 0;
  if TimeoutMs > 0 then
    TimeoutNs := Int64(TimeoutMs) * 1000000;
  Run(nil, TimeoutNs, TimeoutMs = 0, NewAttempt('poll', [], [Fds, N]));
end;

function TPSPNet.TryPoll(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var Fds := Cardinal(A.Arg(0));
  var N := Integer(A.Arg(1));
  var R: TArray<Cardinal>;
  SetLength(R, N);
  var Count := 0;
  for var I := 0 to N - 1 do
  begin
    var E := FMemory.Read16(Fds + Cardinal(I * 8) + 4);
    var S := SockOf(Integer(FMemory.Read32(Fds + Cardinal(I * 8))));
    if S = nil then
      R[I] := POLLNVAL
    else
    begin
      if ((E and (POLLIN or POLLRDNORM)) <> 0) and Readable(S) then
        R[I] := R[I] or (E and (POLLIN or POLLRDNORM));
      if ((E and POLLOUT) <> 0) and Writable(S) then
        R[I] := R[I] or POLLOUT;
      if S.SoError <> 0 then
        R[I] := R[I] or POLLERR;
      if S.CantRecvMore and S.CantSendMore and (S.Kind = 1) and (S.State = isClosed) then
        R[I] := R[I] or POLLHUP;
    end;
    if R[I] <> 0 then
      Inc(Count);
  end;
  Result := (Count > 0) or Final;
  if not Result then
    Exit;
  for var I := 0 to N - 1 do
    FMemory.Write16(Fds + Cardinal(I * 8) + 6, R[I]);
  Ret := Count;
  Err := 0;
end;

procedure TPSPNet.hInetGetErrno;
begin
  var E := 0;
  if FKernel.Current <> nil then
    FErrno.TryGetValue(FKernel.Current.UID, E);
  FHLE.Result(Cardinal(E));
end;

procedure TPSPNet.hInetGetPspError;
begin
  FHLE.Result(0);
end;

procedure TPSPNet.hInetSocketAbort;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  for var W in FWaiters.ToArray do
    if W.Sock = S then
      InetAbortThread(W.Thread);
  InetOk(0);
end;

procedure TPSPNet.CbStat(Stream: Boolean);
begin
  // Newest first, each entry's first word pointing at the next.
  var SizePtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  if SizePtr = 0 then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var Entry := 24;
  var Kind := 2;
  if Stream then
  begin
    Entry := 28;
    Kind := 1;
  end;
  var List: TArray<TInetSocket> := nil;
  for var S in FPcbs do
    if S.Kind = Kind then
      List := List + [S];
  var Need := Length(List) * Entry;
  if Buf <> 0 then
  begin
    var Fit := Min(Length(List), Integer(FMemory.Read32(SizePtr)) div Entry);
    for var I := 0 to Fit - 1 do
    begin
      var S := List[I];
      var P := Buf + Cardinal(I * Entry);
      FMemory.Fill(P, 0, Entry);
      if I < Fit - 1 then
        FMemory.Write32(P, P + Cardinal(Entry));
      if Stream then
      begin
        FMemory.Write32(P + 4, Cardinal(S.RecvLen));
        FMemory.Write32(P + 8, Cardinal(S.SendLen));
        FMemory.Write32(P + 24, Cardinal(Ord(S.State)));
      end
      else
        FMemory.Write32(P + 4, Cardinal(S.QueuedBytes));
      for var K := 0 to 3 do
      begin
        FMemory.Write8(P + 12 + Cardinal(K), (S.LocalIP shr (24 - 8 * K)) and $FF);
        FMemory.Write8(P + 16 + Cardinal(K), (S.PeerIP shr (24 - 8 * K)) and $FF);
      end;
      FMemory.Write8(P + 20, S.LocalPort shr 8);
      FMemory.Write8(P + 21, S.LocalPort and $FF);
      FMemory.Write8(P + 22, S.PeerPort shr 8);
      FMemory.Write8(P + 23, S.PeerPort and $FF);
    end;
  end;
  FMemory.Write32(SizePtr, Cardinal(Need));
  InetOk(0);
end;

procedure TPSPNet.hInetGetUdpcbstat;
begin
  CbStat(False);
end;

procedure TPSPNet.hInetGetTcpcbstat;
begin
  CbStat(True);
end;

{ Addresses }

// inet_aton: one to four parts, each decimal, octal or hex.
function InetAtonText(const S: RawByteString; out Addr: Cardinal): Boolean;
begin
  Result := False;
  var Parts: array[0..2] of Cardinal;
  var NParts := 0;
  var I := 1;
  var N := Length(S);
  var Val: Cardinal;
  while True do
  begin
    if (I > N) or not CharInSet(S[I], ['0'..'9']) then
      Exit;
    Val := 0;
    var Base := 10;
    if S[I] = '0' then
    begin
      Inc(I);
      if (I <= N) and CharInSet(S[I], ['x', 'X']) then
      begin
        Base := 16;
        Inc(I);
      end
      else
        Base := 8;
    end;
    while I <= N do
    begin
      var C := S[I];
      if CharInSet(C, ['0'..'9']) then
        Val := Val * Cardinal(Base) + Cardinal(Ord(C) - Ord('0'))
      else if (Base = 16) and CharInSet(C, ['a'..'f']) then
        Val := (Val shl 4) or Cardinal(Ord(C) - Ord('a') + 10)
      else if (Base = 16) and CharInSet(C, ['A'..'F']) then
        Val := (Val shl 4) or Cardinal(Ord(C) - Ord('A') + 10)
      else
        Break;
      Inc(I);
    end;
    if (I <= N) and (S[I] = '.') then
    begin
      if NParts >= 3 then
        Exit;
      Parts[NParts] := Val;
      Inc(NParts);
      Inc(I);
    end
    else
      Break;
  end;
  if (I <= N) and not CharInSet(S[I], [#9, #10, #11, #12, #13, ' ']) then
    Exit;
  case NParts of
    1:
      begin
        if (Val > $FFFFFF) or (Parts[0] > $FF) then
          Exit;
        Val := Val or (Parts[0] shl 24);
      end;
    2:
      begin
        if (Val > $FFFF) or (Parts[0] > $FF) or (Parts[1] > $FF) then
          Exit;
        Val := Val or (Parts[0] shl 24) or (Parts[1] shl 16);
      end;
    3:
      begin
        if (Val > $FF) or (Parts[0] > $FF) or (Parts[1] > $FF) or (Parts[2] > $FF) then
          Exit;
        Val := Val or (Parts[0] shl 24) or (Parts[1] shl 16) or (Parts[2] shl 8);
      end;
  end;
  Addr := Val;
  Result := True;
end;

// inet_pton: four decimal parts without leading zeros.
function InetPtonText(const S: RawByteString; out Addr: Cardinal): Boolean;
begin
  Result := False;
  var I := 1;
  var N := Length(S);
  Addr := 0;
  for var Part := 0 to 3 do
  begin
    if Part > 0 then
    begin
      if (I > N) or (S[I] <> '.') then
        Exit;
      Inc(I);
    end;
    var Start := I;
    var V := 0;
    while (I <= N) and CharInSet(S[I], ['0'..'9']) do
    begin
      V := V * 10 + Ord(S[I]) - Ord('0');
      if V > 255 then
        Exit;
      Inc(I);
    end;
    if (I = Start) or ((I - Start > 1) and (S[Start] = '0')) then
      Exit;
    Addr := (Addr shl 8) or Cardinal(V);
  end;
  if (I <= N) and not CharInSet(S[I], [#9, #10, #11, #12, #13, ' ']) then
    Exit;
  Result := True;
end;

function NetOrder(Addr: Cardinal): Cardinal;
begin
  Result := (Addr shr 24) or ((Addr shr 8) and $FF00) or ((Addr shl 8) and $FF0000) or (Addr shl 24);
end;

procedure TPSPNet.hInetInetAddr;
begin
  var A: Cardinal;
  if InetAtonText(FMemory.ReadAnsi(FHLE.Arg(0), 256), A) then
    FHLE.Result(NetOrder(A))
  else
    FHLE.Result($FFFFFFFF);
end;

procedure TPSPNet.hInetInetAton;
begin
  var A: Cardinal;
  if InetAtonText(FMemory.ReadAnsi(FHLE.Arg(0), 256), A) then
  begin
    if FHLE.Arg(1) <> 0 then
      FMemory.Write32(FHLE.Arg(1), NetOrder(A));
    FHLE.Result(1);
  end
  else
    FHLE.Result(0);
end;

procedure TPSPNet.hInetInetPton;
begin
  if FHLE.ArgInt(0) <> INET_AF_INET then
  begin
    InetFail(EAFNOSUPPORT);
    Exit;
  end;
  var A: Cardinal;
  if InetPtonText(FMemory.ReadAnsi(FHLE.Arg(1), 256), A) then
  begin
    FMemory.Write32(FHLE.Arg(2), NetOrder(A));
    InetOk(1);
  end
  else
    InetOk(0);
end;

procedure TPSPNet.hInetInetNtop;
begin
  var Src := FHLE.Arg(1);
  var Dst := FHLE.Arg(2);
  var Size := FHLE.ArgInt(3);
  if FHLE.ArgInt(0) <> INET_AF_INET then
  begin
    InetFail(EAFNOSUPPORT);
    FHLE.Result(0);
    Exit;
  end;
  var S := RawByteString(Format('%d.%d.%d.%d',
      [FMemory.Read8(Src), FMemory.Read8(Src + 1), FMemory.Read8(Src + 2), FMemory.Read8(Src + 3)]));
  if Length(S) + 1 > Size then
  begin
    InetFail(ENOSPC);
    FHLE.Result(0);
    Exit;
  end;
  FMemory.WriteString(Dst, S, Length(S) + 1);
  InetOk(Integer(Dst));
end;

procedure TPSPNet.InetRegister;
const
  I = 'sceNetInet';
begin
  var X := FHLE;
  X.Register(I, $17943399, 'sceNetInetInit', hInetInit);
  X.Register(I, $A9ED66B9, 'sceNetInetTerm', hInetTerm);
  X.Register(I, $8B7B220F, 'sceNetInetSocket', hInetSocket);
  X.Register(I, $1A33F9AE, 'sceNetInetBind', hInetBind);
  X.Register(I, $D10A1A7A, 'sceNetInetListen', hInetListen);
  X.Register(I, $DB094E1B, 'sceNetInetAccept', hInetAccept);
  X.Register(I, $410B34AA, 'sceNetInetConnect', hInetConnect);
  X.Register(I, $7AA671BC, 'sceNetInetSend', hInetSend);
  X.Register(I, $05038FC7, 'sceNetInetSendto', hInetSendto);
  X.Register(I, $774E36F4, 'sceNetInetSendmsg', hInetSendmsg);
  X.Register(I, $CDA85C99, 'sceNetInetRecv', hInetRecv);
  X.Register(I, $C91142E4, 'sceNetInetRecvfrom', hInetRecvfrom);
  X.Register(I, $EECE61D2, 'sceNetInetRecvmsg', hInetRecvmsg);
  X.Register(I, $8D7284EA, 'sceNetInetClose', hInetClose);
  X.Register(I, $805502DD, 'sceNetInetCloseWithRST', hInetCloseWithRST);
  X.Register(I, $4CFE4E56, 'sceNetInetShutdown', hInetShutdown);
  X.Register(I, $162E6FD5, 'sceNetInetGetsockname', hInetGetsockname);
  X.Register(I, $E247B6D6, 'sceNetInetGetpeername', hInetGetpeername);
  X.Register(I, $2FE71FE7, 'sceNetInetSetsockopt', hInetSetsockopt);
  X.Register(I, $4A114C7C, 'sceNetInetGetsockopt', hInetGetsockopt);
  X.Register(I, $5BE8D595, 'sceNetInetSelect', hInetSelect);
  X.Register(I, $FAABB1DD, 'sceNetInetPoll', hInetPoll);
  X.Register(I, $FBABE411, 'sceNetInetGetErrno', hInetGetErrno);
  X.Register(I, $8CA3A97E, 'sceNetInetGetPspError', hInetGetPspError);
  X.Register(I, $80A21ABD, 'sceNetInetSocketAbort', hInetSocketAbort);
  X.Register(I, $39B0C7D3, 'sceNetInetGetUdpcbstat', hInetGetUdpcbstat);
  X.Register(I, $B3888AD4, 'sceNetInetGetTcpcbstat', hInetGetTcpcbstat);
  X.Register(I, $B75D5B0A, 'sceNetInetInetAddr', hInetInetAddr);
  X.Register(I, $1BDF5D13, 'sceNetInetInetAton', hInetInetAton);
  X.Register(I, $E30B8C19, 'sceNetInetInetPton', hInetInetPton);
  X.Register(I, $D0792666, 'sceNetInetInetNtop', hInetInetNtop);
  X.Register(I, $2D5868C0, 'sceNetInetDelArp', hZero);
  X.Register(I, $CCC18C45, 'sceNetInetAddArp', hZero);
end;

// Ad hoc on a console alone: adhocctl can create and join groups (nobody
// else is ever in them), scan (and find nobody), discover and wait for game
// mode members who never come. Its handlers run on adhocctl's own thread.

const
  SCE_NET_ADHOCCTL_ERROR_BUSY = Cardinal($80410B02);
  SCE_NET_ADHOCCTL_ERROR_INVALID_ARG = Cardinal($80410B04);
  SCE_NET_ADHOCCTL_ERROR_TIMEOUT = Cardinal($80410B05);
  SCE_NET_ADHOCCTL_ERROR_INVALID_ID = Cardinal($80410B06);
  SCE_NET_ADHOCCTL_ERROR_ALREADY_INITIALIZED = Cardinal($80410B07);
  SCE_NET_ADHOCCTL_ERROR_NOT_INITIALIZED = Cardinal($80410B08);
  SCE_NET_ADHOCCTL_ERROR_NOT_CONNECTED = Cardinal($80410B09);
  SCE_NET_ADHOCCTL_ERROR_NOT_IN_GAMEMODE = Cardinal($80410B0B);
  SCE_NET_ADHOCCTL_ERROR_NOT_ENTER_GAMEMODE = Cardinal($80410B0C);
  SCE_NET_ADHOCCTL_ERROR_HANDLER_MAX = Cardinal($80410B12);
  SCE_NET_ADHOCCTL_ERROR_STACKSIZE_TOO_SHORT = Cardinal($80410B13);
  SCE_NET_ADHOCCTL_ERROR_WLAN_FAILED = Cardinal($80410601);
  SCE_KERNEL_ERROR_ILLEGAL_PRIORITY = Cardinal($80020193);
  SCE_NET_ERROR_NO_ETHER = Cardinal($80410180);
  SCE_NET_ADHOC_ERROR_NO_PEER_LIST = Cardinal($80410682);
  SCE_NET_ADHOC_ERROR_NO_ENTRY = Cardinal($80410716);
  SCE_NET_ADHOC_ERROR_INVALID_MAC = Cardinal($80410702);
  SCE_NET_ADHOC_ERROR_NOT_IN_GAMEMODE = Cardinal($8041071B);
  SCE_NET_ADHOC_ERROR_NOT_CREATED = Cardinal($8041071C);
  SCE_NET_ADHOC_DISCOVER_ERROR_ALREADY_STARTED = Cardinal($80411301);
  SCE_NET_ADHOC_DISCOVER_ERROR_NOT_SUPPORTED = Cardinal($80411303);
  AdhocctlDisconnected = 0;
  AdhocctlConnected = 1;
  AdhocctlDiscovering = 4;
  AdhocEventError = 0;
  AdhocEventConnect = 1;
  AdhocEventDisconnect = 2;
  AdhocEventScan = 3;
  // How long the radio takes for each operation, as hardware measures them.
  AdhocCreateNs = 1115000000;
  AdhocDisconnectNs = 105900000;
  AdhocScanNs = 991800000;
  AdhocQuickNs = 5000000;
  // GetParameter asks the WLAN driver and waits for it.
  AdhocParameterNs = 13700000;

procedure TPSPNet.AdhocReset;
begin
  FAdhocctlInited := False;
  FAdhocctlBroken := False;
  FAdhocctlState := AdhocctlDisconnected;
  FAdhocctlWorker := nil;
  FillChar(FAdhocctlHandlers, SizeOf(FAdhocctlHandlers), 0);
  FAdhocId := nil;
  FAdhocGroup := '';
  FAdhocDeviceUp := False;
  FGameModePending := False;
  FDiscoverStatus := 0;
  FDiscoverPhase := 0;
  FAdhocInited := False;
  for var S in FAdhocObjs do
    if not FAdhocDead.Contains(S) then
      FAdhocDead.Add(S);
  FAdhocObjs.Clear;
  FAdhocDead.Clear;
  FNextAdhocId := 0;
  FNextAdhocPort := $1000;
  FMatchingInited := False;
  FMatching.Clear;
  FLastMatchingId := 0;
end;

procedure TPSPNet.AdhocctlEvent(Event: Integer; Error: Cardinal; DelayNs: Int64; const Change: IPSPStateAction);
begin
  // The radio does its part, then the handlers hear of it on adhocctl's thread.
  var W := FAdhocctlWorker;
  var ID: Cardinal := 0;
  if W <> nil then
    ID := W.Thread.UID;
  FKernel.AddStateTimer(FKernel.Scheduler.Now + DelayNs, Self, TPSPStateAction.Create(StateAdhocEvent, [],
      [ID, Event, Error], '', Change));
end;

procedure TPSPNet.StateAdhocEvent(Action: TPSPStateAction; Value: Cardinal);
begin
  var W := WorkerById(Cardinal(Action.Arg(0)));
  if (W = nil) or (W <> FAdhocctlWorker) then
    Exit;
  if Action.Next <> nil then
    Action.Next.Run;
  if Action.Arg(1) >= 0 then
    Post(W, TPSPStateAction.Create(StateNetJob, [], [Action.Arg(0), Action.Arg(1), Action.Arg(2)], 'adhoc-event'));
end;

procedure TPSPNet.StateAdhocChange(Action: TPSPStateAction; Value: Cardinal);
begin
  case Action.Arg(0) of
    0:
      begin
        FAdhocctlState := AdhocctlConnected;
        FAdhocGroup := RawByteString(Action.Text);
      end;
    1:
      begin
        FAdhocctlState := AdhocctlDisconnected;
        FAdhocGroup := '';
      end;
    2:
      if FDiscoverStatus = 1 then
        FAdhocctlState := AdhocctlDiscovering;
    3:
      if FAdhocctlState = AdhocctlDiscovering then
        FAdhocctlState := AdhocctlDisconnected;
  else
    raise EReadError.Create('Invalid adhoc transition');
  end;
end;

function TPSPNet.AdhocctlReady: Boolean;
begin
  if FAdhocctlInited then
    Result := True
  else
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_INITIALIZED);
    Result := False;
  end;
end;

function TPSPNet.ValidGroupName(Ptr: Cardinal; out Name: RawByteString): Boolean;
begin
  // Up to eight letters and digits.
  Name := '';
  if Ptr = 0 then
    Exit(True);
  for var I := 0 to 7 do
  begin
    var C := AnsiChar(FMemory.Read8(Ptr + Cardinal(I)));
    if C = #0 then
      Break;
    if not CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9']) then
      Exit(False);
    Name := Name + C;
  end;
  Result := True;
end;

function TPSPNet.ReadMac(Addr: Cardinal): TAdhocMac;
begin
  for var I := 0 to 5 do
    Result[I] := FMemory.Read8(Addr + Cardinal(I));
end;

function TPSPNet.IsLocalMac(const M: TAdhocMac): Boolean;
begin
  Result := CompareMem(@M[0], @PSPEtherAddr[0], 6);
end;

// 0 zero, 1 broadcast, 2 multicast, 3 unicast.
function TPSPNet.MacKind(const M: TAdhocMac): Integer;
begin
  var Zero := True;
  var Ones := True;
  for var B in M do
  begin
    Zero := Zero and (B = 0);
    Ones := Ones and (B = $FF);
  end;
  if Zero then
    Result := 0
  else if Ones then
    Result := 1
  else if (M[0] and 1) <> 0 then
    Result := 2
  else
    Result := 3;
end;

{ sceNetAdhocctl }

procedure TPSPNet.hAdhocctlInit;
begin
  var Stack := FHLE.Arg(0);
  var Prio := FHLE.ArgInt(1);
  var Id := FHLE.Arg(2);
  if FAdhocctlBroken then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_WLAN_FAILED);
    Exit;
  end;
  if FAdhocctlInited then
  begin
    // A second Init takes the library down with it.
    StopWorker(FAdhocctlWorker);
    FAdhocctlInited := False;
    FAdhocctlBroken := True;
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_ALREADY_INITIALIZED);
    Exit;
  end;
  if Stack < $C00 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_STACKSIZE_TOO_SHORT);
    Exit;
  end;
  if (Prio < 1) or (Prio > $7F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  if (Id = 0) or (FMemory.Read32(Id) > 2) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  SetLength(FAdhocId, 16);
  FMemory.ReadBytes(Id, FAdhocId[0], 16);
  FAdhocctlWorker := StartWorker('SceNetAdhocctl', Prio, Stack);
  FAdhocctlInited := True;
  FAdhocctlState := AdhocctlDisconnected;
  FAdhocDeviceUp := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlTerm;
begin
  if FAdhocctlInited then
  begin
    if FGameModePending then
      FKernel.CancelTimer(FGameModeTimer);
    StopWorker(FAdhocctlWorker);
  end;
  FAdhocctlInited := False;
  FAdhocctlBroken := False;
  FAdhocctlState := AdhocctlDisconnected;
  FGameModePending := False;
  FillChar(FAdhocctlHandlers, SizeOf(FAdhocctlHandlers), 0);
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlAddHandler;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  for var I := 0 to High(FAdhocctlHandlers) do
    if not FAdhocctlHandlers[I].Used then
    begin
      FAdhocctlHandlers[I].Used := True;
      FAdhocctlHandlers[I].Func := FHLE.Arg(0);
      FAdhocctlHandlers[I].Arg := FHLE.Arg(1);
      FHLE.Result(Cardinal(I));
      Exit;
    end;
  FHLE.Result(SCE_NET_ADHOCCTL_ERROR_HANDLER_MAX);
end;

procedure TPSPNet.hAdhocctlDelHandler;
begin
  if not AdhocctlReady then
    Exit;
  var Id := FHLE.ArgInt(0);
  if (Id < 0) or (Id > High(FAdhocctlHandlers)) or not FAdhocctlHandlers[Id].Used then
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ID)
  else
  begin
    FAdhocctlHandlers[Id].Used := False;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hAdhocctlGetState;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(0), Cardinal(FAdhocctlState));
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlCreate;
begin
  // Nobody has the group, so joining it creates it too.
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  if not ValidGroupName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  AdhocctlEvent(AdhocEventConnect, 0, AdhocCreateNs, TPSPStateAction.Create(StateAdhocChange, [], [0], string(Name)));
end;

procedure TPSPNet.hAdhocctlConnect;
begin
  hAdhocctlCreate;
end;

procedure TPSPNet.hAdhocctlJoin;
begin
  if not AdhocctlReady then
    Exit;
  var Info := FHLE.Arg(0);
  if Info = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  var Name: RawByteString;
  ValidGroupName(Info + 8, Name);
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  AdhocctlEvent(AdhocEventConnect, 0, AdhocCreateNs, TPSPStateAction.Create(StateAdhocChange, [], [0], string(Name)));
end;

procedure TPSPNet.hAdhocctlScan;
begin
  if not AdhocctlReady then
    Exit;
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  AdhocctlEvent(AdhocEventScan, 0, AdhocScanNs, nil);
end;

procedure TPSPNet.hAdhocctlDisconnect;
begin
  // Once the radio is up, leaving reports itself even with nothing to leave.
  if not AdhocctlReady then
    Exit;
  FHLE.Result(0);
  if FGameModePending then
  begin
    FKernel.CancelTimer(FGameModeTimer);
    FGameModePending := False;
  end;
  if (FAdhocctlState <> AdhocctlDisconnected) or FAdhocDeviceUp then
    AdhocctlEvent(AdhocEventDisconnect, 0, AdhocDisconnectNs, TPSPStateAction.Create(StateAdhocChange, [], [1]));
end;

procedure TPSPNet.hAdhocctlGetParameter;
begin
  if not AdhocctlReady then
    Exit;
  var P := FHLE.Arg(0);
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_CONNECTED);
    Exit;
  end;
  if P = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Fill(P, 0, 148);
  FMemory.Write32(P, 1);
  for var I := 1 to Length(FAdhocGroup) do
    FMemory.Write8(P + 3 + Cardinal(I), Ord(FAdhocGroup[I]));
  FMemory.WriteString(P + 12, UTF8Encode(PSPSettings.Nickname), 128);
  // The group's BSSID: a locally administered address the host makes up.
  var Bssid := PSPEtherAddr;
  Bssid[0] := (Bssid[0] or 2) and not 1;
  Bssid[5] := Bssid[5] xor $5A;
  FMemory.WriteBytes(P + 140, Bssid[0], 6);
  Run(nil, AdhocParameterNs, False, NewAttempt('delay', [], []));
end;

procedure TPSPNet.hAdhocctlGetPeerList;
begin
  // Nobody else is ever in the group.
  if not AdhocctlReady then
    Exit;
  var SizePtr := FHLE.Arg(0);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(SizePtr, 0);
  if FAdhocctlState <> AdhocctlConnected then
    FHLE.Result(SCE_NET_ADHOC_ERROR_NO_PEER_LIST)
  else
    FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlGetPeerInfo;
begin
  if not AdhocctlReady then
    Exit;
  FHLE.Result(SCE_NET_ADHOC_ERROR_NO_ENTRY);
end;

procedure TPSPNet.hAdhocctlGetScanInfo;
begin
  if not AdhocctlReady then
    Exit;
  var SizePtr := FHLE.Arg(0);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(SizePtr, 0);
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlGetAdhocId;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.WriteBytes(FHLE.Arg(0), FAdhocId[0], Length(FAdhocId));
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlGetNameByAddr;
begin
  if not AdhocctlReady then
    Exit;
  var Mac := FHLE.Arg(0);
  var Nick := FHLE.Arg(1);
  if (Mac = 0) or (Nick = 0) then
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG)
  else if IsLocalMac(ReadMac(Mac)) then
  begin
    FMemory.WriteString(Nick, UTF8Encode(PSPSettings.Nickname), 128);
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_NET_ADHOC_ERROR_NO_ENTRY);
end;

procedure TPSPNet.hAdhocctlGetAddrByName;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(1) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), 0);
  FHLE.Result(0);
end;

{ Game mode }

procedure TPSPNet.GameModeEnter(Group: Cardinal; TimeoutUs: Cardinal; const Members: TAdhocMac; HasMembers: Boolean);
begin
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  // A master stays in its game mode group until it exits it; a member that
  // found no master has nothing to leave.
  FGameModePending := HasMembers;
  if HasMembers and not IsLocalMac(Members) then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOC_ERROR_INVALID_MAC, AdhocQuickNs, nil);
    Exit;
  end;
  // The other members never answer.
  var W := FAdhocctlWorker;
  var ID: Cardinal := 0;
  if W <> nil then
    ID := W.Thread.UID;
  FGameModeTimer := FKernel.AddStateTimer(FKernel.Scheduler.Now + Int64(TimeoutUs) * 1000, Self,
    TPSPStateAction.Create(StateGameModeTimeout, [], [ID]));
end;

procedure TPSPNet.StateGameModeTimeout(Action: TPSPStateAction; Value: Cardinal);
begin
  var W := WorkerById(Cardinal(Action.Arg(0)));
  if (W = nil) or (W <> FAdhocctlWorker) then
    Exit;
  Post(W, TPSPStateAction.Create(StateNetJob, [], [Action.Arg(0), AdhocEventError, SCE_NET_ADHOCCTL_ERROR_TIMEOUT],
      'adhoc-event'));
end;

function GameModeMaxMembers(Kind: Integer): Integer;
begin
  case Kind of
    1:
      Result := 4;
    2:
      Result := 8;
  else
    Result := 16;
  end;
end;

procedure TPSPNet.hAdhocctlCreateEnterGameMode;
begin
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  var Kind := FHLE.ArgInt(1);
  var Num := FHLE.ArgInt(2);
  var Macs := FHLE.Arg(3);
  if (FHLE.Arg(0) = 0) or not ValidGroupName(FHLE.Arg(0), Name) or (Macs = 0) or (Kind < 1) or (Kind > 3) or
    (Num < 2) or (Num > GameModeMaxMembers(Kind)) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  GameModeEnter(FHLE.Arg(0), FHLE.Arg(4), ReadMac(Macs), True);
end;

procedure TPSPNet.hAdhocctlCreateEnterGameModeMin;
begin
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  var Kind := FHLE.ArgInt(1);
  var MinNum := FHLE.ArgInt(2);
  var Num := FHLE.ArgInt(3);
  var Macs := FHLE.Arg(4);
  if (FHLE.Arg(0) = 0) or not ValidGroupName(FHLE.Arg(0), Name) or (Macs = 0) or (Kind < 1) or (Kind > 3) or
    (MinNum < 2) or (MinNum > Num) or (Num > GameModeMaxMembers(Kind)) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  GameModeEnter(FHLE.Arg(0), FHLE.Arg(5), ReadMac(Macs), True);
end;

procedure TPSPNet.hAdhocctlJoinEnterGameMode;
begin
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  if (FHLE.Arg(0) = 0) or not ValidGroupName(FHLE.Arg(0), Name) or (FHLE.Arg(1) = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  GameModeEnter(FHLE.Arg(0), FHLE.Arg(2), PSPEtherAddr, False);
end;

procedure TPSPNet.hAdhocctlExitGameMode;
begin
  if not AdhocctlReady then
    Exit;
  if FAdhocctlState = AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_IN_GAMEMODE);
    Exit;
  end;
  FHLE.Result(0);
  if FGameModePending then
  begin
    FKernel.CancelTimer(FGameModeTimer);
    FGameModePending := False;
    AdhocctlEvent(AdhocEventDisconnect, 0, AdhocQuickNs, nil);
  end;
end;

procedure TPSPNet.hAdhocctlGetGameModeInfo;
begin
  FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_ENTER_GAMEMODE);
end;

procedure TPSPNet.hGameModeNotInMode;
begin
  FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_IN_GAMEMODE);
end;

procedure TPSPNet.hGameModeDeleteNotInMode;
begin
  FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CREATED);
end;

{ sceNetAdhocDiscover }

// Phases: 0 started, 1 discovering, 2 stop asked, 3 leaving, 4 left.
procedure TPSPNet.hDiscoverInitStart;
begin
  if FDiscoverStatus <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_DISCOVER_ERROR_ALREADY_STARTED);
    Exit;
  end;
  FDiscoverStatus := 1;
  FDiscoverPhase := 0;
  FDiscoverParam := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPNet.hDiscoverUpdate;
begin
  // The discovery advances as the program pumps it.
  FHLE.Result(0);
  if FDiscoverStatus <> 1 then
    Exit;
  case FDiscoverPhase of
    0:
      begin
        FDiscoverPhase := 1;
        FAdhocDeviceUp := True;
        AdhocctlEvent(-1, 0, AdhocQuickNs, TPSPStateAction.Create(StateAdhocChange, [], [2]));
      end;
    2:
      begin
        FDiscoverPhase := 3;
        AdhocctlEvent(AdhocEventDisconnect, 0, AdhocQuickNs, TPSPStateAction.Create(StateAdhocChange, [], [3]));
      end;
    3:
      if FAdhocctlState <> AdhocctlDiscovering then
        FDiscoverPhase := 4;
    4:
      begin
        FDiscoverStatus := 2;
        if FDiscoverParam <> 0 then
          FMemory.Write32(FDiscoverParam + 16, 1);
      end;
  end;
end;

procedure TPSPNet.hDiscoverGetStatus;
begin
  FHLE.Result(Cardinal(FDiscoverStatus));
end;

procedure TPSPNet.hDiscoverStop;
begin
  if (FDiscoverStatus = 1) and (FDiscoverPhase < 2) then
    FDiscoverPhase := 2;
  FHLE.Result(0);
end;

procedure TPSPNet.hDiscoverTerm;
begin
  if FAdhocctlState = AdhocctlDiscovering then
    FAdhocctlState := AdhocctlDisconnected;
  FDiscoverStatus := 0;
  FDiscoverPhase := 0;
  FHLE.Result(0);
end;

procedure TPSPNet.hDiscoverRequestSuspend;
begin
  FHLE.Result(SCE_NET_ADHOC_DISCOVER_ERROR_NOT_SUPPORTED);
end;

// sceNetAdhoc sockets in a group of one: PDP datagrams and PTP connections
// reach this console's own sockets (broadcasts are not looped back), and
// whatever goes to another address is lost. Socket alerts make the calls
// they name fail at once, and wake the threads blocked in them.

const
  SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID = Cardinal($80410701);
  SCE_NET_ADHOC_ERROR_INVALID_PORT = Cardinal($80410703);
  SCE_NET_ADHOC_ERROR_INVALID_DATALEN = Cardinal($80410705);
  SCE_NET_ADHOC_ERROR_SOCKET_DELETED = Cardinal($80410707);
  SCE_NET_ADHOC_ERROR_SOCKET_ALERTED = Cardinal($80410708);
  SCE_NET_ADHOC_ERROR_WOULD_BLOCK = Cardinal($80410709);
  SCE_NET_ADHOC_ERROR_PORT_IN_USE = Cardinal($8041070A);
  SCE_NET_ADHOC_ERROR_NOT_CONNECTED = Cardinal($8041070B);
  SCE_NET_ADHOC_ERROR_DISCONNECTED = Cardinal($8041070C);
  SCE_NET_ADHOC_ERROR_NOT_LISTENED = Cardinal($8040070E);
  SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL = Cardinal($8041070F);
  SCE_NET_ADHOC_ERROR_INVALID_ARG = Cardinal($80410711);
  SCE_NET_ADHOC_ERROR_NOT_INITIALIZED = Cardinal($80410712);
  SCE_NET_ADHOC_ERROR_ALREADY_INITIALIZED = Cardinal($80410713);
  SCE_NET_ADHOC_ERROR_TIMEOUT = Cardinal($80410715);
  SCE_NET_ADHOC_ERROR_EXCEPTION_EVENT = Cardinal($80410717);
  SCE_NET_ADHOC_ERROR_CONNECTION_REFUSED = Cardinal($80410718);
  SCE_NET_ADHOC_ERROR_NOT_ENOUGH_SPACE = Cardinal($80400706);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MODE = Cardinal($80410801);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MAXNUM = Cardinal($80410803);
  SCE_NET_ADHOC_MATCHING_ERROR_RXBUF_TOO_SHORT = Cardinal($80410804);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG = Cardinal($80410806);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID = Cardinal($80410807);
  SCE_NET_ADHOC_MATCHING_ERROR_ID_NOT_AVAIL = Cardinal($80410808);
  SCE_NET_ADHOC_MATCHING_ERROR_IS_RUNNING = Cardinal($8041080A);
  SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING = Cardinal($8041080B);
  SCE_NET_ADHOC_MATCHING_ERROR_UNKNOWN_TARGET = Cardinal($8041080C);
  SCE_NET_ADHOC_MATCHING_ERROR_ALREADY_INITIALIZED = Cardinal($80410812);
  SCE_NET_ADHOC_MATCHING_ERROR_NOT_INITIALIZED = Cardinal($80410813);
  SCE_NET_ADHOC_MATCHING_ERROR_PORT_IN_USE = Cardinal($80410814);
  SCE_NET_ADHOC_MATCHING_ERROR_STACKSIZE_TOO_SHORT = Cardinal($80410815);
  AlertSend = $10;
  AlertRecv = $20;
  AlertPoll = $40;
  AlertConnect = $80;
  AlertAccept = $100;
  AlertFlush = $200;
  AlertMask = $3F0;
  EvSend = $1;
  EvRecv = $2;
  EvConnect = $4;
  EvAccept = $8;
  EvFlush = $10;
  EvInvalid = $100;
  EvAlert = $400;
  EvError = $800;
  AdhocMaxSockets = 255;
  AdhocMaxDatagram = 65523;
  MatchingMaxContexts = 15;

{ TAdhocSocket }

constructor TAdhocSocket.Create;
begin
  inherited Create;
  Queue := TQueue<TAdhocDatagram>.Create;
  Pending := TList<TAdhocSocket>.Create;
end;

destructor TAdhocSocket.Destroy;
begin
  Queue.Free;
  Pending.Free;
  inherited;
end;

{ Sockets }

function TPSPNet.AdhocObj(Id: Integer): TAdhocSocket;
begin
  if Id > 0 then
    for var S in FAdhocObjs do
      if S.Id = Id then
        Exit(S);
  Result := nil;
end;

function TPSPNet.AdhocNewId: Integer;
begin
  Inc(FNextAdhocId);
  Result := FNextAdhocId;
end;

function TPSPNet.AdhocCount: Integer;
begin
  Result := 0;
  for var S in FAdhocObjs do
    if S.Id > 0 then
      Inc(Result);
end;

function TPSPNet.AdhocPortUsed(Ptp: Boolean; Port: Integer): Boolean;
begin
  for var S in FAdhocObjs do
    if (S.Ptp = Ptp) and (S.Port = Port) and (S.Id > 0) and (not Ptp or (S.State = 1)) then
      Exit(True);
  Result := False;
end;

function TPSPNet.PtpListenerFor(Port: Integer): TAdhocSocket;
begin
  for var S in FAdhocObjs do
    if S.Ptp and (S.State = 1) and (S.Port = Port) and not S.Deleted then
      Exit(S);
  Result := nil;
end;

procedure TPSPNet.AdhocDrop(S: TAdhocSocket);
begin
  S.Deleted := True;
  if S.Peer <> nil then
  begin
    S.Peer.PeerClosed := True;
    S.Peer.State := 0;
    S.Peer.Peer := nil;
    S.Peer := nil;
  end;
  for var P in S.Pending.ToArray do
    AdhocDrop(P);
  S.Pending.Clear;
  InetWake;
  if FAdhocObjs.Remove(S) >= 0 then
    FAdhocDead.Add(S);
end;

procedure TPSPNet.AdhocWait(TimeoutUs: Cardinal; NonBlocking: Boolean; const Attempt: TInetAttempt);
begin
  Run(nil, Int64(TimeoutUs) * 1000, NonBlocking, Attempt);
end;

procedure TPSPNet.hAdhocInit;
begin
  if FAdhocInited then
    FHLE.Result(SCE_NET_ADHOC_ERROR_ALREADY_INITIALIZED)
  else
  begin
    FAdhocInited := True;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hAdhocTerm;
begin
  for var S in FAdhocObjs.ToArray do
    if FAdhocObjs.Contains(S) then
      AdhocDrop(S);
  FAdhocInited := False;
  FHLE.Result(0);
end;

function NextAdhocPort(Net: TPSPNet; Ptp: Boolean): Integer;
begin
  repeat
    Inc(Net.FNextAdhocPort);
    if Net.FNextAdhocPort > $7FFF then
      Net.FNextAdhocPort := $1001;
  until not Net.AdhocPortUsed(Ptp, Net.FNextAdhocPort);
  Result := Net.FNextAdhocPort;
end;

procedure TPSPNet.hPdpCreate;
begin
  var MacPtr := FHLE.Arg(0);
  var Port := Integer(FHLE.Arg(1) and $FFFF);
  var BufSize := FHLE.ArgInt(2);
  var Flag := FHLE.ArgInt(3);
  if not FAdhocInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (Flag <> 0) or (MacPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC);
    Exit;
  end;
  // The id is taken before the address is looked at.
  var Id := AdhocNewId;
  if not IsLocalMac(ReadMac(MacPtr)) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if Port = $FFFF then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if (Port <> 0) and AdhocPortUsed(False, Port) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_PORT_IN_USE)
  else if AdhocCount >= AdhocMaxSockets then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL)
  else
  begin
    if Port = 0 then
      Port := NextAdhocPort(Self, False);
    var S := TAdhocSocket.Create;
    S.Id := Id;
    S.Port := Port;
    S.BufSize := BufSize;
    FAdhocObjs.Add(S);
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.hPdpSend;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Dst := FHLE.Arg(1);
  var Port := Integer(FHLE.Arg(2) and $FFFF);
  var Data := FHLE.Arg(3);
  var Len := FHLE.ArgInt(4);
  var Flag := FHLE.ArgInt(6);
  if ((Flag and not 1) <> 0) or (Dst = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  var Mac := ReadMac(Dst);
  var Kind := MacKind(Mac);
  if Kind in [0, 2] then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if (Port = 0) or (Port = $FFFF) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if (Len < 0) or (Len > AdhocMaxDatagram) or ((Data = 0) and (Len > 0)) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_DATALEN)
  else if (S.Alert and AlertSend) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
  else
  begin
    if (Kind = 3) and IsLocalMac(Mac) then
      for var R in FAdhocObjs do
        if not R.Ptp and (R.Port = Port) and (R.Id > 0) then
        begin
          var D: TAdhocDatagram;
          SetLength(D.Data, Len);
          if Len > 0 then
            FMemory.ReadBytes(Data, D.Data[0], Len);
          D.Port := S.Port;
          R.Queue.Enqueue(D);
          Inc(R.QueuedBytes, Len);
          InetWake;
          Break;
        end;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hPdpRecv;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var MacPtr := FHLE.Arg(1);
  var PortPtr := FHLE.Arg(2);
  var Buf := FHLE.Arg(3);
  var LenPtr := FHLE.Arg(4);
  var Timeout := FHLE.Arg(5);
  var Flag := FHLE.ArgInt(6);
  if ((Flag and not 1) <> 0) or (Buf = 0) or (LenPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking, NewAttempt('pdp-recv', [S], [MacPtr, PortPtr, Buf, LenPtr, Ord(NonBlocking)]));
end;

function TPSPNet.TryPdpRecv(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TAdhocSocket(A.Obj(0));
  var LenPtr := Cardinal(A.Arg(3));
  Result := True;
  Err := 0;
  if S.Deleted then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
  else if (S.Alert and AlertRecv) <> 0 then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
  else if S.Queue.Count > 0 then
  begin
    var D := S.Queue.Peek;
    var Len := Integer(FMemory.Read32(LenPtr));
    if A.Arg(0) <> 0 then
      FMemory.WriteBytes(Cardinal(A.Arg(0)), PSPEtherAddr[0], 6);
    if A.Arg(1) <> 0 then
      FMemory.Write16(Cardinal(A.Arg(1)), Cardinal(D.Port));
    FMemory.Write32(LenPtr, Cardinal(Length(D.Data)));
    if Length(D.Data) > Len then
    begin
      Ret := Integer(SCE_NET_ADHOC_ERROR_NOT_ENOUGH_SPACE);
      Exit;
    end;
    S.Queue.Dequeue;
    Dec(S.QueuedBytes, Length(D.Data));
    if Length(D.Data) > 0 then
      FMemory.WriteBytes(Cardinal(A.Arg(2)), D.Data[0], Length(D.Data));
    Ret := 0;
  end
  else if Final then
    if A.Arg(4) <> 0 then
      Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
    else
      Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT)
  else
    Result := False;
end;

procedure TPSPNet.hPdpDelete;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if FHLE.ArgInt(1) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else if (S = nil) or S.Ptp then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else
  begin
    AdhocDrop(S);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hGetPdpStat;
begin
  // Oldest first; the size comes back as what was written.
  var SizePtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  var List: TArray<TAdhocSocket> := nil;
  for var S in FAdhocObjs do
    if not S.Ptp and (S.Id > 0) then
      List := List + [S];
  if Buf = 0 then
  begin
    FMemory.Write32(SizePtr, Cardinal(Length(List) * 20));
    FHLE.Result(0);
    Exit;
  end;
  var Fit := Min(Length(List), Integer(FMemory.Read32(SizePtr)) div 20);
  for var I := 0 to Fit - 1 do
  begin
    var P := Buf + Cardinal(I * 20);
    if I < Fit - 1 then
      FMemory.Write32(P, P + 20)
    else
      FMemory.Write32(P, 0);
    FMemory.Write32(P + 4, Cardinal(List[I].ID));
    FMemory.WriteBytes(P + 8, PSPEtherAddr[0], 6);
    FMemory.Write16(P + 14, Cardinal(List[I].Port));
    FMemory.Write32(P + 16, Cardinal(List[I].QueuedBytes));
  end;
  FMemory.Write32(SizePtr, Cardinal(Fit * 20));
  FHLE.Result(0);
end;

procedure TPSPNet.hPtpOpen;
begin
  var MacPtr := FHLE.Arg(0);
  var Port := Integer(FHLE.Arg(1) and $FFFF);
  var Dst := FHLE.Arg(2);
  var DPort := Integer(FHLE.Arg(3) and $FFFF);
  var BufSize := FHLE.ArgInt(4);
  var Flag := FHLE.ArgInt(7);
  if not FAdhocInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (Flag <> 0) or (MacPtr = 0) or (Dst = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC);
    Exit;
  end;
  var Id := AdhocNewId;
  var DstMac := ReadMac(Dst);
  if not IsLocalMac(ReadMac(MacPtr)) or (MacKind(DstMac) in [0, 2]) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if (DPort = 0) or (DPort = $FFFF) or (Port = $FFFF) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if AdhocCount >= AdhocMaxSockets then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL)
  else
  begin
    if Port = 0 then
      Port := NextAdhocPort(Self, True);
    var S := TAdhocSocket.Create;
    S.Id := Id;
    S.Ptp := True;
    S.Port := Port;
    S.BufSize := BufSize;
    S.PeerMac := DstMac;
    S.PeerPort := DPort;
    S.State := 2;
    FAdhocObjs.Add(S);
    if IsLocalMac(DstMac) then
    begin
      // The SYN reaches this console at once.
      var L := PtpListenerFor(DPort);
      if L = nil then
      begin
        S.State := 0;
        S.Refused := True;
      end
      else
      begin
        var A := TAdhocSocket.Create;
        A.Id := -1;
        A.Ptp := True;
        A.Port := DPort;
        A.BufSize := L.BufSize;
        A.PeerMac := PSPEtherAddr;
        A.PeerPort := Port;
        A.State := 4;
        A.Peer := S;
        S.Peer := A;
        S.State := 4;
        L.Pending.Add(A);
        FAdhocObjs.Add(A);
      end;
      InetWake;
    end;
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.hPtpListen;
begin
  var MacPtr := FHLE.Arg(0);
  var Port := Integer(FHLE.Arg(1) and $FFFF);
  var BufSize := FHLE.ArgInt(2);
  var Flag := FHLE.ArgInt(6);
  if not FAdhocInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (Flag <> 0) or (MacPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC);
    Exit;
  end;
  var Id := AdhocNewId;
  if not IsLocalMac(ReadMac(MacPtr)) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if Port = $FFFF then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if (Port <> 0) and AdhocPortUsed(True, Port) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_PORT_IN_USE)
  else if AdhocCount >= AdhocMaxSockets then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL)
  else
  begin
    if Port = 0 then
      Port := NextAdhocPort(Self, True);
    var S := TAdhocSocket.Create;
    S.Id := Id;
    S.Ptp := True;
    S.Port := Port;
    S.BufSize := BufSize;
    S.State := 1;
    FAdhocObjs.Add(S);
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.hPtpConnect;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Timeout := FHLE.Arg(1);
  var Flag := FHLE.ArgInt(2);
  if (Flag and not 1) <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State = 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking, NewAttempt('ptp-connect', [S], [Ord(NonBlocking)]));
end;

function TPSPNet.TryPtpConnect(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TAdhocSocket(A.Obj(0));
  Result := True;
  Err := 0;
  if S.State = 4 then
    Ret := 0
  else if S.Refused then
    Ret := Integer(SCE_NET_ADHOC_ERROR_CONNECTION_REFUSED)
  else if S.Deleted then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
  else if S.PeerClosed then
    Ret := Integer(SCE_NET_ADHOC_ERROR_DISCONNECTED)
  else if (S.Alert and AlertConnect) <> 0 then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
  else if Final then
    if A.Arg(0) <> 0 then
      Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
    else
      Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT)
  else
    Result := False;
end;

procedure TPSPNet.hPtpAccept;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var MacPtr := FHLE.Arg(1);
  var PortPtr := FHLE.Arg(2);
  var Timeout := FHLE.Arg(3);
  var Flag := FHLE.ArgInt(4);
  if (Flag and not 1) <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State <> 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_LISTENED);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking, NewAttempt('ptp-accept', [S], [MacPtr, PortPtr, Ord(NonBlocking)]));
end;

function TPSPNet.TryPtpAccept(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TAdhocSocket(A.Obj(0));
  Result := True;
  Err := 0;
  if S.Deleted then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
  else if (S.Alert and AlertAccept) <> 0 then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
  else if S.Pending.Count > 0 then
  begin
    var N := S.Pending[0];
    S.Pending.Delete(0);
    N.Id := AdhocNewId;
    if A.Arg(0) <> 0 then
      FMemory.WriteBytes(Cardinal(A.Arg(0)), N.PeerMac[0], 6);
    if A.Arg(1) <> 0 then
      FMemory.Write16(Cardinal(A.Arg(1)), Cardinal(N.PeerPort));
    Ret := N.Id;
  end
  else if Final then
    if A.Arg(2) <> 0 then
      Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
    else
      Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT)
  else
    Result := False;
end;

procedure TPSPNet.hPtpSend;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Data := FHLE.Arg(1);
  var LenPtr := FHLE.Arg(2);
  var Flag := FHLE.ArgInt(4);
  if ((Flag and not 1) <> 0) or (LenPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State = 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var Len := Integer(FMemory.Read32(LenPtr));
  if (Len < 0) or ((Data = 0) and (Len > 0)) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_DATALEN);
    Exit;
  end;
  if S.PeerClosed or S.Refused or (S.State = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_DISCONNECTED);
    Exit;
  end;
  if (S.Alert and AlertSend) <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED);
    Exit;
  end;
  if S.State <> 4 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var P := S.Peer;
  if (P <> nil) and (Len > 0) then
  begin
    if Length(P.RecvData) < P.RecvLen + Len then
      SetLength(P.RecvData, P.RecvLen + Len);
    FMemory.ReadBytes(Data, P.RecvData[P.RecvLen], Len);
    Inc(P.RecvLen, Len);
    InetWake;
  end;
  FHLE.Result(0);
end;

procedure TPSPNet.hPtpRecv;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Buf := FHLE.Arg(1);
  var LenPtr := FHLE.Arg(2);
  var Timeout := FHLE.Arg(3);
  var Flag := FHLE.ArgInt(4);
  if ((Flag and not 1) <> 0) or (Buf = 0) or (LenPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State = 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking, NewAttempt('ptp-recv', [S], [Buf, LenPtr, Ord(NonBlocking)]));
end;

function TPSPNet.TryPtpRecv(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var S := TAdhocSocket(A.Obj(0));
  var LenPtr := Cardinal(A.Arg(1));
  Result := True;
  Err := 0;
  if S.Deleted then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
  else if (S.Alert and AlertRecv) <> 0 then
    Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
  else if S.RecvLen > 0 then
  begin
    var N := Max(0, Min(Integer(FMemory.Read32(LenPtr)), S.RecvLen));
    if N > 0 then
      FMemory.WriteBytes(Cardinal(A.Arg(0)), S.RecvData[0], N);
    Move(S.RecvData[N], S.RecvData[0], S.RecvLen - N);
    Dec(S.RecvLen, N);
    FMemory.Write32(LenPtr, Cardinal(N));
    Ret := 0;
  end
  else if S.PeerClosed or S.Refused then
    Ret := Integer(SCE_NET_ADHOC_ERROR_DISCONNECTED)
  else if Final then
    if A.Arg(2) <> 0 then
      Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
    else
      Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT)
  else
    Result := False;
end;

procedure TPSPNet.hPtpFlush;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if (FHLE.ArgInt(2) and not 1) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else if (S = nil) or not S.Ptp then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else if S.State = 1 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED)
  else if S.PeerClosed or S.Refused then
    FHLE.Result(SCE_NET_ADHOC_ERROR_DISCONNECTED)
  else
    // Everything sent has already arrived.
    FHLE.Result(0);
end;

procedure TPSPNet.hPtpClose;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if FHLE.ArgInt(1) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else if (S = nil) or not S.Ptp then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else
  begin
    AdhocDrop(S);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hGetPtpStat;
begin
  var SizePtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  var List: TArray<TAdhocSocket> := nil;
  for var S in FAdhocObjs do
    if S.Ptp then
      List := List + [S];
  if Buf = 0 then
  begin
    FMemory.Write32(SizePtr, Cardinal(Length(List) * 36));
    FHLE.Result(0);
    Exit;
  end;
  var Fit := Min(Length(List), Integer(FMemory.Read32(SizePtr)) div 36);
  for var I := 0 to Fit - 1 do
  begin
    var S := List[I];
    var P := Buf + Cardinal(I * 36);
    FMemory.Fill(P, 0, 36);
    if I < Fit - 1 then
      FMemory.Write32(P, P + 36);
    FMemory.Write32(P + 4, Cardinal(S.Id));
    FMemory.WriteBytes(P + 8, PSPEtherAddr[0], 6);
    if S.State <> 1 then
    begin
      FMemory.WriteBytes(P + 14, S.PeerMac[0], 6);
      FMemory.Write16(P + 22, Cardinal(S.PeerPort));
    end;
    FMemory.Write16(P + 20, Cardinal(S.Port));
    FMemory.Write32(P + 28, Cardinal(S.RecvLen));
    FMemory.Write32(P + 32, Cardinal(S.State));
  end;
  FMemory.Write32(SizePtr, Cardinal(Fit * 36));
  FHLE.Result(0);
end;

procedure TPSPNet.hSetSocketAlert;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if S = nil then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  S.Alert := FHLE.Arg(1) and AlertMask;
  FHLE.Result(0);
  InetWake;
end;

procedure TPSPNet.hGetSocketAlert;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if S = nil then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else if FHLE.Arg(1) = 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else
  begin
    FMemory.Write32(FHLE.Arg(1), S.Alert);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hPollSocket;
begin
  var Sds := FHLE.Arg(0);
  var Count := FHLE.ArgInt(1);
  var Timeout := FHLE.Arg(2);
  var Flag := FHLE.ArgInt(3);
  if ((Flag and not 1) <> 0) or (Count <= 0) or (Sds = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  for var I := 0 to Count - 1 do
    if AdhocObj(Integer(FMemory.Read32(Sds + Cardinal(I * 12)))) = nil then
    begin
      // The firmware marks the first entry, whichever was bad.
      FMemory.Write32(Sds + 8, EvInvalid);
      FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
      Exit;
    end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking, NewAttempt('adhoc-poll', [], [Sds, Count, Ord(NonBlocking)]));
end;

function TPSPNet.TryAdhocPoll(A: TPSPStateAction; Final: Boolean; out Ret, Err: Integer): Boolean;
begin
  var Sds := Cardinal(A.Arg(0));
  var Count := Integer(A.Arg(1));
  Err := 0;
  var R: TArray<Cardinal>;
  SetLength(R, Count);
  var Ready := 0;
  var Failed := False;
  for var I := 0 to Count - 1 do
  begin
    var S := AdhocObj(Integer(FMemory.Read32(Sds + Cardinal(I * 12))));
    var Events := FMemory.Read32(Sds + Cardinal(I * 12) + 4);
    if (S = nil) or S.Deleted then
    begin
      R[I] := EvInvalid;
      Failed := True;
      Continue;
    end;
    if (S.Alert and AlertPoll) <> 0 then
    begin
      R[I] := EvAlert;
      Failed := True;
      Continue;
    end;
    var V: Cardinal := 0;
    if not S.Ptp then
    begin
      V := EvSend;
      if S.Queue.Count > 0 then
        V := V or EvRecv;
    end
    else
      case S.State of
        1:
          begin
            V := EvSend or EvFlush;
            if S.Pending.Count > 0 then
              V := V or EvAccept;
          end;
        4:
          if S.PeerClosed then
            V := EvError
          else
          begin
            V := EvSend or EvConnect or EvFlush;
            if S.RecvLen > 0 then
              V := V or EvRecv;
          end;
        0:
          V := EvError;
      end;
    if (V and EvError) <> 0 then
    begin
      R[I] := EvError;
      Failed := True;
      Continue;
    end;
    R[I] := V and Events;
    if R[I] <> 0 then
      Inc(Ready);
  end;
  Result := Failed or (Ready > 0) or Final;
  if not Result then
    Exit;
  for var I := 0 to Count - 1 do
    FMemory.Write32(Sds + Cardinal(I * 12) + 8, R[I]);
  if Failed then
    Ret := Integer(SCE_NET_ADHOC_ERROR_EXCEPTION_EVENT)
  else if (Ready = 0) and (A.Arg(2) = 0) then
    Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT)
  else
    Ret := Ready;
end;

{ sceNetAdhocMatching }

procedure TPSPNet.hMatchingInit;
begin
  if FMatchingInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_ALREADY_INITIALIZED);
    Exit;
  end;
  FMatchingInited := True;
  FMatchingPool := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingTerm;
begin
  FMatchingInited := False;
  FMatching.Clear;
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingCreate;
begin
  var Mode := FHLE.ArgInt(0);
  var MaxNum := FHLE.ArgInt(1);
  var Port := Integer(FHLE.Arg(2) and $FFFF);
  var RxBufLen := FHLE.ArgInt(3);
  var Hello := FHLE.Arg(4);
  var KeepAlive := FHLE.Arg(5);
  var Count := FHLE.ArgInt(6);
  var Rexmt := FHLE.Arg(7);
  if not FMatchingInited then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_INITIALIZED)
  else if (Mode < 1) or (Mode > 3) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MODE)
  else if (MaxNum < 2) or (MaxNum > 16) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MAXNUM)
  else if RxBufLen < 6 * MaxNum + 4 then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_RXBUF_TOO_SHORT)
  else if (Rexmt = 0) or (Count < 0) or ((Mode <> 2) and ((Hello = 0) or (KeepAlive = 0))) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG)
  else
  begin
    for var C in FMatching.Values do
      if C.Port = Port then
      begin
        FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_PORT_IN_USE);
        Exit;
      end;
    if FMatching.Count >= MatchingMaxContexts then
    begin
      FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_ID_NOT_AVAIL);
      Exit;
    end;
    // Ids go round 1..15.
    var Id := FLastMatchingId;
    repeat
      Id := Id mod MatchingMaxContexts + 1;
    until not FMatching.ContainsKey(Id);
    FLastMatchingId := Id;
    var C := TMatchingContext.Create;
    C.Id := Id;
    C.Mode := Mode;
    C.MaxNum := MaxNum;
    C.Port := Port;
    FMatching.Add(Id, C);
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.MatchingStart(Id, StackA, StackB: Integer; PartA, PartB: Integer; OptLen: Integer; Opt: Cardinal);
begin
  var C: TMatchingContext;
  if not FMatching.TryGetValue(Id, C) then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID);
    Exit;
  end;
  if (StackA < $200) or (StackB < $200) then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_STACKSIZE_TOO_SHORT);
    Exit;
  end;
  if not (PartA in [2, 5, 6]) or not (PartB in [2, 5, 6]) then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID);
    Exit;
  end;
  if C.Running then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_IS_RUNNING);
    Exit;
  end;
  C.Running := True;
  SetLength(C.HelloOpt, Max(OptLen, 0));
  if (OptLen > 0) and (Opt <> 0) then
    FMemory.ReadBytes(Opt, C.HelloOpt[0], OptLen);
  // Its threads would report peers; there never are any.
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingStart;
begin
  MatchingStart(FHLE.ArgInt(0), FHLE.ArgInt(2), FHLE.ArgInt(4), 2, 2, FHLE.ArgInt(5), FHLE.Arg(6));
end;

procedure TPSPNet.hMatchingStart2;
begin
  // The ninth argument is on the stack.
  var Opt := FMemory.Read32(FSystem.CPU.Ctx.GPR[29]);
  MatchingStart(FHLE.ArgInt(0), FHLE.ArgInt(2), FHLE.ArgInt(5), FHLE.ArgInt(3), FHLE.ArgInt(6), FHLE.ArgInt(7), Opt);
end;

procedure TPSPNet.hMatchingStop;
begin
  var C: TMatchingContext;
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else
  begin
    C.Running := False;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingDelete;
begin
  var C: TMatchingContext;
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_IS_RUNNING)
  else
  begin
    FMatching.Remove(C.Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingRunning;
begin
  // The calls about a target: nobody is ever a known one.
  var C: TMatchingContext;
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_UNKNOWN_TARGET);
end;

procedure TPSPNet.hMatchingSetHelloOpt;
begin
  var C: TMatchingContext;
  var Len := FHLE.ArgInt(1);
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else
  begin
    SetLength(C.HelloOpt, Max(Len, 0));
    if (Len > 0) and (FHLE.Arg(2) <> 0) then
      FMemory.ReadBytes(FHLE.Arg(2), C.HelloOpt[0], Len);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingGetHelloOpt;
begin
  // Copies as much as asked for out of the context, where the data is
  // followed by the context's mode; the length is left as the caller gave it.
  var C: TMatchingContext;
  var LenPtr := FHLE.Arg(1);
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else if LenPtr = 0 then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG)
  else
  begin
    var Stored := C.HelloOpt + [Byte(C.Mode)];
    var N := EnsureRange(Integer(FMemory.Read32(LenPtr)), 0, 256);
    SetLength(Stored, Max(N, Length(Stored)));
    if (N > 0) and (FHLE.Arg(2) <> 0) then
      FMemory.WriteBytes(FHLE.Arg(2), Stored[0], N);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingGetMembers;
begin
  // Only this console.
  var C: TMatchingContext;
  var SizePtr := FHLE.Arg(1);
  var Buf := FHLE.Arg(2);
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else if SizePtr = 0 then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG)
  else
  begin
    if (Buf <> 0) and (Integer(FMemory.Read32(SizePtr)) >= 12) then
    begin
      FMemory.Fill(Buf, 0, 12);
      FMemory.WriteBytes(Buf + 4, PSPEtherAddr[0], 6);
    end;
    FMemory.Write32(SizePtr, 12);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingGetPoolMaxAlloc;
begin
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingGetPoolStat;
begin
  var P := FHLE.Arg(0);
  if P = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG);
    Exit;
  end;
  var Pool := FMatchingPool - NetPoolReserved;
  FMemory.Write32(P, Pool);
  FMemory.Write32(P + 4, 0);
  FMemory.Write32(P + 8, Pool);
  FHLE.Result(0);
end;

procedure TPSPNet.AdhocRegister;
const
  C = 'sceNetAdhocctl';
  A = 'sceNetAdhoc';
  M = 'sceNetAdhocMatching';
  D = 'sceNetAdhocDiscover';
begin
  var X := FHLE;
  X.Register(C, $E26F226E, 'sceNetAdhocctlInit', hAdhocctlInit);
  X.Register(C, $9D689E13, 'sceNetAdhocctlTerm', hAdhocctlTerm);
  X.Register(C, $20B317A0, 'sceNetAdhocctlAddHandler', hAdhocctlAddHandler);
  X.Register(C, $6402490B, 'sceNetAdhocctlDelHandler', hAdhocctlDelHandler);
  X.Register(C, $75ECD386, 'sceNetAdhocctlGetState', hAdhocctlGetState);
  X.Register(C, $EC0635C1, 'sceNetAdhocctlCreate', hAdhocctlCreate);
  X.Register(C, $0AD043ED, 'sceNetAdhocctlConnect', hAdhocctlConnect);
  X.Register(C, $5E7F79C9, 'sceNetAdhocctlJoin', hAdhocctlJoin);
  X.Register(C, $08FFF7A0, 'sceNetAdhocctlScan', hAdhocctlScan);
  X.Register(C, $34401D65, 'sceNetAdhocctlDisconnect', hAdhocctlDisconnect);
  X.Register(C, $DED9D28E, 'sceNetAdhocctlGetParameter', hAdhocctlGetParameter);
  X.Register(C, $E162CB14, 'sceNetAdhocctlGetPeerList', hAdhocctlGetPeerList);
  X.Register(C, $8DB83FDC, 'sceNetAdhocctlGetPeerInfo', hAdhocctlGetPeerInfo);
  X.Register(C, $81AEE1BE, 'sceNetAdhocctlGetScanInfo', hAdhocctlGetScanInfo);
  X.Register(C, $362CBE8F, 'sceNetAdhocctlGetAdhocId', hAdhocctlGetAdhocId);
  X.Register(C, $8916C003, 'sceNetAdhocctlGetNameByAddr', hAdhocctlGetNameByAddr);
  X.Register(C, $99560ABE, 'sceNetAdhocctlGetAddrByName', hAdhocctlGetAddrByName);
  X.Register(C, $A5C055CE, 'sceNetAdhocctlCreateEnterGameMode', hAdhocctlCreateEnterGameMode);
  X.Register(C, $B0B80E80, 'sceNetAdhocctlCreateEnterGameModeMin', hAdhocctlCreateEnterGameModeMin);
  X.Register(C, $1FF89745, 'sceNetAdhocctlJoinEnterGameMode', hAdhocctlJoinEnterGameMode);
  X.Register(C, $CF8E084D, 'sceNetAdhocctlExitGameMode', hAdhocctlExitGameMode);
  X.Register(C, $5A014CE0, 'sceNetAdhocctlGetGameModeInfo', hAdhocctlGetGameModeInfo);

  X.Register(A, $E1D621D7, 'sceNetAdhocInit', hAdhocInit);
  X.Register(A, $A62C6F57, 'sceNetAdhocTerm', hAdhocTerm);
  X.Register(A, $6F92741B, 'sceNetAdhocPdpCreate', hPdpCreate);
  X.Register(A, $ABED3790, 'sceNetAdhocPdpSend', hPdpSend);
  X.Register(A, $DFE53E03, 'sceNetAdhocPdpRecv', hPdpRecv);
  X.Register(A, $7F27BB5E, 'sceNetAdhocPdpDelete', hPdpDelete);
  X.Register(A, $C7C1FC57, 'sceNetAdhocGetPdpStat', hGetPdpStat);
  X.Register(A, $877F6D66, 'sceNetAdhocPtpOpen', hPtpOpen);
  X.Register(A, $E08BDAC1, 'sceNetAdhocPtpListen', hPtpListen);
  X.Register(A, $FC6FC07B, 'sceNetAdhocPtpConnect', hPtpConnect);
  X.Register(A, $9DF81198, 'sceNetAdhocPtpAccept', hPtpAccept);
  X.Register(A, $4DA4C788, 'sceNetAdhocPtpSend', hPtpSend);
  X.Register(A, $8BEA2B3E, 'sceNetAdhocPtpRecv', hPtpRecv);
  X.Register(A, $9AC2EEAC, 'sceNetAdhocPtpFlush', hPtpFlush);
  X.Register(A, $157E6225, 'sceNetAdhocPtpClose', hPtpClose);
  X.Register(A, $B9685118, 'sceNetAdhocGetPtpStat', hGetPtpStat);
  X.Register(A, $73BFD52D, 'sceNetAdhocSetSocketAlert', hSetSocketAlert);
  X.Register(A, $4D2CE199, 'sceNetAdhocGetSocketAlert', hGetSocketAlert);
  X.Register(A, $7A662D6B, 'sceNetAdhocPollSocket', hPollSocket);
  X.Register(A, $7F75C338, 'sceNetAdhocGameModeCreateMaster', hGameModeNotInMode);
  X.Register(A, $98C204C8, 'sceNetAdhocGameModeUpdateMaster', hGameModeNotInMode);
  X.Register(A, $A0229362, 'sceNetAdhocGameModeDeleteMaster', hGameModeDeleteNotInMode);
  X.Register(A, $3278AB0C, 'sceNetAdhocGameModeCreateReplica', hGameModeNotInMode);
  X.Register(A, $FA324B4E, 'sceNetAdhocGameModeUpdateReplica', hGameModeNotInMode);
  X.Register(A, $0B2228E9, 'sceNetAdhocGameModeDeleteReplica', hGameModeDeleteNotInMode);

  X.Register(M, $2A2A1E07, 'sceNetAdhocMatchingInit', hMatchingInit);
  X.Register(M, $7945ECDA, 'sceNetAdhocMatchingTerm', hMatchingTerm);
  X.Register(M, $CA5EDA6F, 'sceNetAdhocMatchingCreate', hMatchingCreate);
  X.Register(M, $93EF3843, 'sceNetAdhocMatchingStart', hMatchingStart);
  X.Register(M, $E8454C65, 'sceNetAdhocMatchingStart2', hMatchingStart2);
  X.Register(M, $32B156B3, 'sceNetAdhocMatchingStop', hMatchingStop);
  X.Register(M, $F16EAF4F, 'sceNetAdhocMatchingDelete', hMatchingDelete);
  X.Register(M, $5E3D4B79, 'sceNetAdhocMatchingSelectTarget', hMatchingRunning);
  X.Register(M, $EA3C6108, 'sceNetAdhocMatchingCancelTarget', hMatchingRunning);
  X.Register(M, $8F58BEDF, 'sceNetAdhocMatchingCancelTargetWithOpt', hMatchingRunning);
  X.Register(M, $F79472D7, 'sceNetAdhocMatchingSendData', hMatchingRunning);
  X.Register(M, $EC19337D, 'sceNetAdhocMatchingAbortSendData', hMatchingRunning);
  X.Register(M, $B58E61B7, 'sceNetAdhocMatchingSetHelloOpt', hMatchingSetHelloOpt);
  X.Register(M, $B5D96C2A, 'sceNetAdhocMatchingGetHelloOpt', hMatchingGetHelloOpt);
  X.Register(M, $C58BCD9E, 'sceNetAdhocMatchingGetMembers', hMatchingGetMembers);
  X.Register(M, $40F8F435, 'sceNetAdhocMatchingGetPoolMaxAlloc', hMatchingGetPoolMaxAlloc);
  X.Register(M, $9C5CFB7D, 'sceNetAdhocMatchingGetPoolStat', hMatchingGetPoolStat);

  X.Register(D, $941B3877, 'sceNetAdhocDiscoverInitStart', hDiscoverInitStart);
  X.Register(D, $52DE1B97, 'sceNetAdhocDiscoverUpdate', hDiscoverUpdate);
  X.Register(D, $944DDBC6, 'sceNetAdhocDiscoverGetStatus', hDiscoverGetStatus);
  X.Register(D, $A2246614, 'sceNetAdhocDiscoverTerm', hDiscoverTerm);
  X.Register(D, $F7D13214, 'sceNetAdhocDiscoverStop', hDiscoverStop);
  X.Register(D, $A423A21B, 'sceNetAdhocDiscoverRequestSuspend', hDiscoverRequestSuspend);
end;

{ TPSPNetWorker }

constructor TPSPNetWorker.Create;
begin
  inherited Create;
  Jobs := TQueue<TNetJob>.Create;
  Calls := TQueue<TNetCall>.Create;
end;

destructor TPSPNetWorker.Destroy;
begin
  Jobs.Free;
  Calls.Free;
  inherited;
end;

{ TPSPNet }

constructor TPSPNet.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FWorkers := TObjectList<TPSPNetWorker>.Create;
  FResolvers := TObjectDictionary<Integer, TNetResolver>.Create([doOwnsValues]);
  FHttpIds := TDictionary<Cardinal, Integer>.Create;
  FSockets := TDictionary<Integer, TInetSocket>.Create;
  FPcbs := TList<TInetSocket>.Create;
  FDeadPcbs := TObjectList<TInetSocket>.Create;
  FWaiters := TObjectList<TInetWaiter>.Create;
  FErrno := TDictionary<Cardinal, Integer>.Create;
  FAdhocObjs := TList<TAdhocSocket>.Create;
  FAdhocDead := TObjectList<TAdhocSocket>.Create;
  FMatching := TObjectDictionary<Integer, TMatchingContext>.Create([doOwnsValues]);
end;

destructor TPSPNet.Destroy;
begin
  FWorkers.Free;
  FResolvers.Free;
  FHttpIds.Free;
  FWaiters.Free;
  FSockets.Free;
  for var S in FPcbs do
    if not FDeadPcbs.Contains(S) then
      FDeadPcbs.Add(S);
  FPcbs.Free;
  FDeadPcbs.Free;
  FErrno.Free;
  for var S in FAdhocObjs do
    if not FAdhocDead.Contains(S) then
      FAdhocDead.Add(S);
  FAdhocObjs.Free;
  FAdhocDead.Free;
  FMatching.Free;
  inherited;
end;

procedure TPSPNet.Reset;
begin
  FWorkers.Clear;
  FApctlWorker := nil;
  FNetInited := False;
  FApctlInited := False;
  FApctlState := ApctlStateDisconnected;
  FillChar(FApctlHandlers, SizeOf(FApctlHandlers), 0);
  FScanning := False;
  FResolverInited := False;
  FResolvers.Clear;
  FNextResolver := 1;
  FHttpInited := False;
  FHttpIds.Clear;
  FNextTemplate := 1;
  FNextConnection := $01000001;
  FNextRequest := $02000001;
  FUsbStarted := False;
  FUsbActivated := False;
  InetReset;
  AdhocReset;
  FWorkerStub := FKernel.AllocKernel(16, 'net thread');
end;

{ Library threads }

function TPSPNet.StartWorker(const Name: string; Priority: Integer; StackSize: Cardinal): TPSPNetWorker;
begin
  Result := nil;
  // The library threads loop on: syscall; j loop.
  FMemory.Write32(FWorkerStub, (Cardinal(FWorkerIndex) shl 6) or $0C);
  FMemory.Write32(FWorkerStub + 4, (2 shl 26) or ((FWorkerStub shr 2) and $03FFFFFF));
  FMemory.Write32(FWorkerStub + 8, 0);
  var T := FKernel.CreateThread(Name, FWorkerStub, Priority, Max(StackSize, $800), 0, FSystem.CPU.Ctx.GPR[28]);
  if T = nil then
    Exit;
  Result := TPSPNetWorker.Create;
  Result.Thread := T;
  FWorkers.Add(Result);
  FKernel.StartThread(T, 0, 0);
end;

procedure TPSPNet.StopWorker(var W: TPSPNetWorker);
begin
  if W = nil then
    Exit;
  var T := W.Thread;
  if T <> nil then
  begin
    if T <> FKernel.Current then
    begin
      FKernel.TerminateThread(T, 0);
      FKernel.DeleteThread(T);
    end;
  end;
  FWorkers.Remove(W);
  W := nil;
end;

procedure TPSPNet.Post(W: TPSPNetWorker; const Job: IPSPStateAction);
begin
  if W = nil then
    Exit;
  var Work: TNetJob;
  Work.Action := Job;
  W.Jobs.Enqueue(Work);
  var T := W.Thread;
  if T.IsWaiting and (T.Wait.HLETag = 'net thread') then
    FKernel.EndWait(T, 0);
end;

function TPSPNet.WorkerById(Id: Cardinal): TPSPNetWorker;
begin
  Result := nil;
  if Id = 0 then
    Exit;
  for var W in FWorkers do
    if (W.Thread <> nil) and FKernel.Threads.Contains(W.Thread) and (W.Thread.UID = Id) then
      Exit(W);
end;

procedure TPSPNet.QueueCalls(W: TPSPNetWorker; const Work: TArray<TNetCall>);
begin
  for var C in Work do
    W.Calls.Enqueue(C);
end;

procedure TPSPNet.StateNetJob(Action: TPSPStateAction; Value: Cardinal);
begin
  var W := WorkerById(Cardinal(Action.Arg(0)));
  if W = nil then
    Exit;
  if Action.Text = 'apctl-state' then
  begin
    FApctlState := Integer(Action.Arg(2));
    QueueCalls(W, Calls(FApctlHandlers,
        [Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)), Cardinal(Action.Arg(3)), 0]));
  end
  else if Action.Text = 'apctl-scan' then
  begin
    var Old := FApctlState;
    FApctlState := ApctlStateDisconnected;
    FScanning := False;
    QueueCalls(W, Calls(FApctlHandlers, [Cardinal(Old), ApctlStateDisconnected, ApctlEventScanComplete, 0]));
  end
  else if Action.Text = 'adhoc-event' then
    QueueCalls(W, Calls(FAdhocctlHandlers, [Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2))]))
  else
    raise EReadError.Create('Invalid network worker operation');
end;

function TPSPNet.Calls(const Handlers: array of TNetHandler; const Args: array of Cardinal): TArray<TNetCall>;
begin
  Result := nil;
  for var H in Handlers do
    if H.Used then
    begin
      var C: TNetCall;
      C.Func := H.Func;
      SetLength(C.Args, Length(Args) + 1);
      for var I := 0 to High(Args) do
        C.Args[I] := Args[I];
      C.Args[Length(Args)] := H.Arg;
      Result := Result + [C];
    end;
end;

procedure TPSPNet.hWorker;
begin
  var T := FKernel.Current;
  var W: TPSPNetWorker := nil;
  for var X in FWorkers do
    if X.Thread = T then
      W := X;
  if W = nil then
  begin
    FKernel.ExitCurrent(0);
    Exit;
  end;
  while (W.Calls.Count = 0) and (W.Jobs.Count > 0) do
    W.Jobs.Dequeue().Action.Run;
  if W.Calls.Count > 0 then
  begin
    var C := W.Calls.Dequeue;
    FKernel.CallGuest(C.Func, C.Args, nil);
  end
  else
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'net thread');
end;

{ sceNet }

procedure TPSPNet.hNetInit;
begin
  FNetInited := True;
  FPoolSize := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPNet.hNetTerm;
begin
  FNetInited := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hNetEtherNtostr;
const
  Hex: array[0..15] of AnsiChar = '0123456789abcdef';
begin
  var Mac := FHLE.Arg(0);
  var Name := FHLE.Arg(1);
  if (Mac = 0) or (Name = 0) then
  begin
    // The firmware returns the high half of its own data address here.
    FHLE.Result($09D40000);
    Exit;
  end;
  var S: RawByteString := '';
  for var I := 0 to 5 do
  begin
    var B := FMemory.Read8(Mac + Cardinal(I));
    if I > 0 then
      S := S + ':';
    S := S + Hex[B shr 4] + Hex[B and 15];
  end;
  FMemory.WriteString(Name, S, 18);
  FHLE.Result(Length(S));
end;

// The firmware's digit: a letter counts as a base-36 digit and anything
// else as 9999999, with no checking.
function EtherDigit(C: Cardinal): Integer;
begin
  case C of
    Ord('0')..Ord('9'):
      Result := Integer(C) - Ord('0');
    Ord('A')..Ord('Z'):
      Result := Integer(C) - Ord('A') + 10;
    Ord('a')..Ord('z'):
      Result := Integer(C) - Ord('a') + 10;
  else
    Result := 9999999;
  end;
end;

procedure TPSPNet.hNetEtherStrton;
begin
  // Two characters per byte and one separator after each, whatever they
  // are; it reads past the end of a short string.
  var Name := FHLE.Arg(0);
  var Mac := FHLE.Arg(1);
  if (Name = 0) or (Mac = 0) then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var V: Integer;
  for var I := 0 to 5 do
  begin
    var P := Name + Cardinal(I * 3);
    V := EtherDigit(FMemory.Read8(P)) * 16 + EtherDigit(FMemory.Read8(P + 1));
    FMemory.Write8(Mac + Cardinal(I), Cardinal(V) and $FF);
  end;
  FHLE.Result(Cardinal(V));
end;

procedure TPSPNet.hNetGetLocalEtherAddr;
begin
  // Known once a group or scan operation has brought the radio up.
  var Mac := FHLE.Arg(0);
  if Mac = 0 then
  begin
    FHLE.Result(SCE_NET_ERROR_INVALID_ARG);
    Exit;
  end;
  if not FAdhocDeviceUp then
  begin
    FHLE.Result($80410180);
    Exit;
  end;
  FMemory.WriteBytes(Mac, PSPEtherAddr[0], 6);
  FHLE.Result(0);
end;

procedure TPSPNet.hNetGetMallocStat;
begin
  var Stat := FHLE.Arg(0);
  if Stat = 0 then
  begin
    FHLE.Result(SCE_NET_ERROR_INVALID_ARG);
    Exit;
  end;
  var Pool := FPoolSize - NetPoolReserved;
  FMemory.Write32(Stat, Pool);
  FMemory.Write32(Stat + 4, Min(Pool, NetPoolPeak));
  FMemory.Write32(Stat + 8, Pool - Min(Pool div 2, NetPoolUsed));
  FHLE.Result(0);
end;

procedure TPSPNet.hNetThreadAbort;
begin
  var T: TPSPThread := nil;
  if FHLE.Arg(0) <> 0 then
    T := FKernel.ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_NET_ERROR_INVALID_THREAD);
    Exit;
  end;
  InetAbortThread(T);
  FHLE.Result(0);
end;

procedure TPSPNet.hNetFreeThreadinfo;
begin
  if (FHLE.Arg(0) = 0) or (FKernel.ThreadById(FHLE.Arg(0)) = nil) then
    FHLE.Result(SCE_NET_ERROR_INVALID_THREAD)
  else
  begin
    FErrno.Remove(FHLE.Arg(0));
    FHLE.Result(0);
  end;
end;

{ sceWlanDrv }

procedure TPSPNet.hWlanGetSwitchState;
begin
  FHLE.Result(1);
end;

procedure TPSPNet.hWlanDevIsPowerOn;
begin
  FHLE.Result(1);
end;

procedure TPSPNet.hWlanGetEtherAddr;
begin
  var Mac := FHLE.Arg(0);
  if Mac <> 0 then
    FMemory.WriteBytes(Mac, PSPEtherAddr[0], 6);
  FHLE.Result(0);
end;

{ sceNetApctl }

procedure TPSPNet.ApctlSetState(NewState, Event: Integer);
begin
  // On apctl's thread: the state changes, then the handlers hear of it.
  var Old := FApctlState;
  if FApctlWorker <> nil then
    Post(FApctlWorker, TPSPStateAction.Create(StateNetJob, [], [FApctlWorker.Thread.UID, Old, NewState, Event],
        'apctl-state'));
end;

procedure TPSPNet.hApctlInit;
begin
  if FApctlInited then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_ALREADY_INITIALIZED);
    Exit;
  end;
  FApctlWorker := StartWorker('SceNetApctl', FHLE.ArgInt(1), FHLE.Arg(0));
  FApctlInited := True;
  FApctlState := ApctlStateDisconnected;
  FScanning := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hApctlTerm;
begin
  if FApctlInited then
  begin
    if FScanning then
      FKernel.CancelTimer(FScanTimer);
    StopWorker(FApctlWorker);
    FApctlInited := False;
    FScanning := False;
    FApctlState := ApctlStateDisconnected;
    FillChar(FApctlHandlers, SizeOf(FApctlHandlers), 0);
  end;
  FHLE.Result(0);
end;

procedure TPSPNet.hApctlGetState;
begin
  var P := FHLE.Arg(0);
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if P = 0 then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ARG)
  else
  begin
    FMemory.Write32(P, Cardinal(FApctlState));
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hApctlGetInfo;
begin
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_CONNECTED);
end;

procedure TPSPNet.hApctlAddHandler;
begin
  if not FApctlInited then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  for var I := 0 to High(FApctlHandlers) do
    if not FApctlHandlers[I].Used then
    begin
      if FHLE.Arg(0) = 0 then
        Break;
      FApctlHandlers[I].Used := True;
      FApctlHandlers[I].Func := FHLE.Arg(0);
      FApctlHandlers[I].Arg := FHLE.Arg(1);
      FHLE.Result(Cardinal(I));
      Exit;
    end;
  FHLE.Result(SCE_NET_APCTL_ERROR_TOO_MANY_HANDLERS);
end;

procedure TPSPNet.hApctlDelHandler;
begin
  var Id := FHLE.ArgInt(0);
  if (Id < 0) or (Id > High(FApctlHandlers)) then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ID)
  else if not FApctlHandlers[Id].Used then
    FHLE.Result(SCE_NET_APCTL_ERROR_HANDLER_NOT_FOUND)
  else
  begin
    FApctlHandlers[Id].Used := False;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hApctlConnect;
begin
  // No connection profile is set up on this console.
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if FHLE.ArgInt(0) < 0 then
    FHLE.Result(SCE_UTILITY_ERROR_NETCONF_BAD_PROFILE)
  else
    FHLE.Result(SCE_UTILITY_ERROR_NETCONF_NO_PROFILE);
end;

procedure TPSPNet.hApctlDisconnect;
begin
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else
    FHLE.Result(0);
end;

procedure TPSPNet.hApctlScanUser;
begin
  if not FApctlInited then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if FScanning or (FApctlState <> ApctlStateDisconnected) then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_BUSY);
    Exit;
  end;
  FScanning := True;
  ApctlSetState(ApctlStateScanning, ApctlEventScanRequest);
  FScanTimer := FKernel.AddStateTimer(FKernel.Scheduler.Now + ApctlScanNs, Self,
    TPSPStateAction.Create(StateScanTimer, [], []));
  FHLE.Result(0);
end;

procedure TPSPNet.StateScanTimer(Action: TPSPStateAction; Value: Cardinal);
begin
  if FApctlWorker <> nil then
    Post(FApctlWorker, TPSPStateAction.Create(StateNetJob, [], [FApctlWorker.Thread.UID], 'apctl-scan'));
end;

procedure TPSPNet.hApctlGetBSSDescIDListUser;
begin
  var SizePtr := FHLE.Arg(0);
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if SizePtr = 0 then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ARG)
  else
  begin
    FMemory.Write32(SizePtr, 0);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hApctlGetBSSDescEntryUser;
begin
  var Code := FHLE.ArgInt(1);
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if (Code < 0) or (Code > 5) then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_CODE)
  else
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ID);
end;

procedure TPSPNet.hNotExported;
begin
  // Imported by programs but not in this firmware's library: the kernel's
  // unresolved stub answers.
  FHLE.Result(SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED);
end;

{ sceNetResolver }

function TPSPNet.ResolverOf(Id: Integer): TNetResolver;
begin
  if not FResolvers.TryGetValue(Id, Result) then
    Result := nil;
end;

procedure TPSPNet.hResolverInit;
begin
  if FResolverInited then
    FHLE.Result(SCE_KERNEL_ERROR_ALREADY)
  else
  begin
    FResolverInited := True;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverTerm;
begin
  FResolverInited := False;
  FResolvers.Clear;
  FHLE.Result(0);
end;

procedure TPSPNet.hResolverCreate;
begin
  var RidPtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  var Len := FHLE.Arg(2);
  if (RidPtr = 0) or (Buf = 0) then
  begin
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR);
    Exit;
  end;
  if Len = 0 then
  begin
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_BUFLEN);
    Exit;
  end;
  var R := TNetResolver.Create;
  R.Id := FNextResolver;
  Inc(FNextResolver);
  FResolvers.Add(R.Id, R);
  FMemory.Write32(RidPtr, Cardinal(R.Id));
  FHLE.Result(0);
end;

procedure TPSPNet.hResolverDelete;
begin
  var Id := FHLE.ArgInt(0);
  if not FResolverInited then
    FHLE.Result(0)
  else if ResolverOf(Id) = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else
  begin
    FResolvers.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverStartNtoA;
begin
  // There is no DNS server to ask, not even for a dotted address.
  var R := ResolverOf(FHLE.ArgInt(0));
  var Name := FHLE.Arg(1);
  var Addr := FHLE.Arg(2);
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (Name = 0) or (Addr = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else if FMemory.Read8(Name) = 0 then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_EMPTY_NAME)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER);
end;

procedure TPSPNet.hResolverStartAtoN;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (FHLE.Arg(1) = 0) or (FHLE.Arg(2) = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER);
end;

procedure TPSPNet.hResolverStartNtoAAsync;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (FHLE.Arg(1) = 0) or (FHLE.Arg(2) = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else if R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_BUSY)
  else
  begin
    R.Pending := True;
    if FMemory.Read8(FHLE.Arg(1)) = 0 then
      R.PendingResult := SCE_NET_RESOLVER_ERROR_EMPTY_NAME
    else
      R.PendingResult := SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverStartAtoNAsync;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (FHLE.Arg(1) = 0) or (FHLE.Arg(2) = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else if R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_BUSY)
  else
  begin
    R.Pending := True;
    R.PendingResult := SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverPollAsync;
begin
  // The lookup has already failed: collecting it returns that failure.
  var R := ResolverOf(FHLE.ArgInt(0));
  if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if FHLE.Arg(1) = 0 then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_STATUS_PTR)
  else if not R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_ASYNC)
  else
  begin
    R.Pending := False;
    FHLE.Result(R.PendingResult);
  end;
end;

procedure TPSPNet.hResolverWaitAsync;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if FHLE.Arg(1) = 0 then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_STATUS_PTR)
  else if not R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_ASYNC)
  else
  begin
    R.Pending := False;
    FHLE.Result(R.PendingResult);
  end;
end;

procedure TPSPNet.hResolverStop;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NOT_RUNNING)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NOT_RUNNING);
end;

{ sceHttp }

function TPSPNet.HttpId(Kind: Integer; out Id: Cardinal): Boolean;
begin
  Id := FHLE.Arg(0);
  var K: Integer;
  Result := FHttpIds.TryGetValue(Id, K) and (K = Kind);
end;

procedure TPSPNet.hHttpInit;
begin
  FHttpInited := True;
  FHLE.Result(0);
end;

procedure TPSPNet.hHttpEnd;
begin
  FHttpInited := False;
  FHttpIds.Clear;
  FHLE.Result(0);
end;

procedure TPSPNet.hHttpCreateTemplate;
begin
  var Id := FNextTemplate;
  Inc(FNextTemplate);
  FHttpIds.AddOrSetValue(Id, 0);
  FHLE.Result(Id);
end;

procedure TPSPNet.hHttpCreateConnection;
begin
  var K: Integer;
  if not FHttpIds.TryGetValue(FHLE.Arg(0), K) or (K <> 0) then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID);
    Exit;
  end;
  var Id := FNextConnection;
  Inc(FNextConnection);
  FHttpIds.AddOrSetValue(Id, 1);
  FHLE.Result(Id);
end;

procedure TPSPNet.hHttpCreateRequest;
begin
  var K: Integer;
  if not FHttpIds.TryGetValue(FHLE.Arg(0), K) or (K <> 1) then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID);
    Exit;
  end;
  var Id := FNextRequest;
  Inc(FNextRequest);
  FHttpIds.AddOrSetValue(Id, 2);
  FHLE.Result(Id);
end;

procedure TPSPNet.hHttpDeleteTemplate;
begin
  var Id: Cardinal;
  if not HttpId(0, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
  begin
    FHttpIds.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hHttpDeleteConnection;
begin
  var Id: Cardinal;
  if not HttpId(1, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
  begin
    FHttpIds.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hHttpDeleteRequest;
begin
  var Id: Cardinal;
  if not HttpId(2, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
  begin
    FHttpIds.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hHttpSendRequest;
begin
  // The host name goes to the resolver, which has no server to ask.
  var Id: Cardinal;
  if not HttpId(2, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER);
end;

procedure TPSPNet.hHttpGetContentLength;
begin
  var Id: Cardinal;
  if not HttpId(2, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
    FHLE.Result(SCE_HTTP_ERROR_NO_RESPONSE);
end;

procedure TPSPNet.hHttpGetStatusCode;
begin
  hHttpGetContentLength;
end;

procedure TPSPNet.hHttpReadData;
begin
  hHttpGetContentLength;
end;

procedure TPSPNet.hHttpSetting;
begin
  // Options on a template, connection or request.
  if FHttpIds.ContainsKey(FHLE.Arg(0)) then
    FHLE.Result(0)
  else
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID);
end;

procedure TPSPNet.hZero;
begin
  FHLE.Result(0);
end;

{ sceUsb: drivers start and activate, but no cable is ever plugged in. }

const
  PSP_USB_CONNECTION_NOT_ESTABLISHED = $001;
  PSP_USB_CABLE_DISCONNECTED = $010;
  PSP_USB_DEACTIVATED = $100;
  PSP_USB_ACTIVATED = $200;
  SCE_USB_ERROR_INVALID_ARGUMENT = Cardinal($80243002);
  SCE_KERNEL_ERROR_WAIT_TIMEOUT_USB = Cardinal($800201A8);

procedure TPSPNet.hUsbStart;
begin
  if FHLE.Arg(0) = 0 then
    FHLE.Result(SCE_USB_ERROR_INVALID_ARGUMENT)
  else
  begin
    FUsbStarted := True;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hUsbActivate;
begin
  FUsbActivated := True;
  FHLE.Result(0);
end;

procedure TPSPNet.hUsbDeactivate;
begin
  FUsbActivated := False;
  FHLE.Result(0);
end;

function UsbState(Activated: Boolean): Cardinal;
begin
  Result := PSP_USB_CABLE_DISCONNECTED or PSP_USB_CONNECTION_NOT_ESTABLISHED;
  if Activated then
    Result := Result or PSP_USB_ACTIVATED
  else
    Result := Result or PSP_USB_DEACTIVATED;
end;

procedure TPSPNet.hUsbGetState;
begin
  FHLE.Result(UsbState(FUsbActivated));
end;

procedure TPSPNet.hUsbWaitState;
begin
  // Waits for any (mode 0) or all (mode 1) of the bits; the state never changes.
  var Want := FHLE.Arg(0);
  var State := UsbState(FUsbActivated);
  if ((FHLE.Arg(1) = 0) and ((State and Want) <> 0)) or ((FHLE.Arg(1) <> 0) and ((State and Want) = Want)) then
    FHLE.Result(State)
  else
    FHLE.Result(SCE_KERNEL_ERROR_WAIT_TIMEOUT_USB);
end;

procedure TPSPNet.Register;
const
  N = 'sceNet';
  W = 'sceWlanDrv';
  A = 'sceNetApctl';
  R = 'sceNetResolver';
  H = 'sceHttp';
  S = 'sceSsl';
  U = 'sceParseUri';
begin
  var X := FHLE;
  X.Register('RetroMulNet', 1, 'NetLibraryThread', hWorker);
  FWorkerIndex := X.Find('RetroMulNet', 1);

  X.Register(U, $568518C9, 'sceUriParse', hUriParse);
  X.Register(U, $7EE318AF, 'sceUriBuild', hUriBuild);
  X.Register(U, $49E950EC, 'sceUriEscape', hUriEscape);
  X.Register(U, $062BB07E, 'sceUriUnescape', hUriUnescape);

  X.Register(N, $39AF39A6, 'sceNetInit', hNetInit);
  X.Register(N, $281928A9, 'sceNetTerm', hNetTerm);
  X.Register(N, $89360950, 'sceNetEtherNtostr', hNetEtherNtostr);
  X.Register(N, $D27961C9, 'sceNetEtherStrton', hNetEtherStrton);
  X.Register(N, $0BF0A3AE, 'sceNetGetLocalEtherAddr', hNetGetLocalEtherAddr);
  X.Register(N, $CC393E48, 'sceNetGetMallocStat', hNetGetMallocStat);
  X.Register(N, $AD6844C6, 'sceNetThreadAbort', hNetThreadAbort);
  X.Register(N, $50647530, 'sceNetFreeThreadinfo', hNetFreeThreadinfo);

  X.Register(W, $D7763699, 'sceWlanGetSwitchState', hWlanGetSwitchState);
  X.Register(W, $93440B11, 'sceWlanDevIsPowerOn', hWlanDevIsPowerOn);
  X.Register(W, $0C622081, 'sceWlanGetEtherAddr', hWlanGetEtherAddr);

  X.Register(A, $E2F91F9B, 'sceNetApctlInit', hApctlInit);
  X.Register(A, $B3EDD0EC, 'sceNetApctlTerm', hApctlTerm);
  X.Register(A, $5DEAC81B, 'sceNetApctlGetState', hApctlGetState);
  X.Register(A, $2BEFDF23, 'sceNetApctlGetInfo', hApctlGetInfo);
  X.Register(A, $8ABADD51, 'sceNetApctlAddHandler', hApctlAddHandler);
  X.Register(A, $5963991B, 'sceNetApctlDelHandler', hApctlDelHandler);
  X.Register(A, $CFB957C6, 'sceNetApctlConnect', hApctlConnect);
  X.Register(A, $24FE91A1, 'sceNetApctlDisconnect', hApctlDisconnect);
  X.Register(A, $E9B2E5E6, 'sceNetApctlScanUser', hApctlScanUser);
  X.Register(A, $6BDDCB8C, 'sceNetApctlGetBSSDescIDListUser', hApctlGetBSSDescIDListUser);
  X.Register(A, $04776994, 'sceNetApctlGetBSSDescEntryUser', hApctlGetBSSDescEntryUser);
  X.Register(A, $B3CF6849, 'sceNetApctlScan', hNotExported);
  X.Register(A, $0C7FFA5C, 'sceNetApctlGetBSSDescIDList', hNotExported);
  X.Register(A, $96BEB231, 'sceNetApctlGetBSSDescEntry', hNotExported);

  X.Register(R, $F3370E61, 'sceNetResolverInit', hResolverInit);
  X.Register(R, $6138194A, 'sceNetResolverTerm', hResolverTerm);
  X.Register(R, $244172AF, 'sceNetResolverCreate', hResolverCreate);
  X.Register(R, $94523E09, 'sceNetResolverDelete', hResolverDelete);
  X.Register(R, $224C5F44, 'sceNetResolverStartNtoA', hResolverStartNtoA);
  X.Register(R, $629E2FB7, 'sceNetResolverStartAtoN', hResolverStartAtoN);
  X.Register(R, $14C17EF9, 'sceNetResolverStartNtoAAsync', hResolverStartNtoAAsync);
  X.Register(R, $AAC09184, 'sceNetResolverStartAtoNAsync', hResolverStartAtoNAsync);
  X.Register(R, $4EE99358, 'sceNetResolverPollAsync', hResolverPollAsync);
  X.Register(R, $12748EB9, 'sceNetResolverWaitAsync', hResolverWaitAsync);
  X.Register(R, $808F6063, 'sceNetResolverStop', hResolverStop);

  X.Register(H, $AB1ABE07, 'sceHttpInit', hHttpInit);
  X.Register(H, $D1C8945E, 'sceHttpEnd', hHttpEnd);
  X.Register(H, $9B1F1F36, 'sceHttpCreateTemplate', hHttpCreateTemplate);
  X.Register(H, $4E4A284A, 'sceHttpCloneTemplate', hHttpCreateTemplate);
  X.Register(H, $FCF8C055, 'sceHttpDeleteTemplate', hHttpDeleteTemplate);
  X.Register(H, $8EEFD953, 'sceHttpCreateConnection', hHttpCreateConnection);
  X.Register(H, $CDF8ECB9, 'sceHttpCreateConnectionWithURL', hHttpCreateConnection);
  X.Register(H, $5152773B, 'sceHttpDeleteConnection', hHttpDeleteConnection);
  X.Register(H, $47347B50, 'sceHttpCreateRequest', hHttpCreateRequest);
  X.Register(H, $B509B09E, 'sceHttpCreateRequestWithURL', hHttpCreateRequest);
  X.Register(H, $A5512E01, 'sceHttpDeleteRequest', hHttpDeleteRequest);
  X.Register(H, $BB70706F, 'sceHttpSendRequest', hHttpSendRequest);
  X.Register(H, $9AFC98B2, 'sceHttpSendRequestInCacheFirstMode', hHttpSendRequest);
  X.Register(H, $C10B6BD9, 'sceHttpAbortRequest', hHttpSetting);
  X.Register(H, $0282A3BD, 'sceHttpGetContentLength', hHttpGetContentLength);
  X.Register(H, $4CC7D78F, 'sceHttpGetStatusCode', hHttpGetStatusCode);
  X.Register(H, $EDEEB999, 'sceHttpReadData', hHttpReadData);
  X.Register(H, $3EABA285, 'sceHttpAddExtraHeader', hHttpSetting);
  X.Register(H, $15540184, 'sceHttpDeleteHeader', hHttpSetting);
  X.Register(H, $47940436, 'sceHttpSetResolveTimeOut', hHttpSetting);
  X.Register(H, $03D9526F, 'sceHttpSetResolveRetry', hHttpSetting);
  X.Register(H, $8ACD1F73, 'sceHttpSetConnectTimeOut', hHttpSetting);
  X.Register(H, $9988172D, 'sceHttpSetSendTimeOut', hHttpSetting);
  X.Register(H, $1F0FC3E3, 'sceHttpSetRecvTimeOut', hHttpSetting);
  X.Register(H, $78A0D3EC, 'sceHttpEnableKeepAlive', hHttpSetting);
  X.Register(H, $C7EF2559, 'sceHttpDisableKeepAlive', hHttpSetting);
  X.Register(H, $0809C831, 'sceHttpEnableRedirect', hHttpSetting);
  X.Register(H, $1A0EBB69, 'sceHttpDisableRedirect', hHttpSetting);
  X.Register(H, $0DAFA58F, 'sceHttpEnableCookie', hHttpSetting);
  X.Register(H, $0B12ABFB, 'sceHttpDisableCookie', hHttpSetting);
  X.Register(H, $9FC5F10D, 'sceHttpEnableAuth', hHttpSetting);
  X.Register(H, $AE948FEE, 'sceHttpDisableAuth', hHttpSetting);
  X.Register(H, $59E6D16F, 'sceHttpEnableCache', hHttpSetting);
  X.Register(H, $CCBD167A, 'sceHttpDisableCache', hHttpSetting);
  X.Register(H, $2A6C3296, 'sceHttpSetAuthInfoCB', hHttpSetting);
  X.Register(H, $A4496DE5, 'sceHttpSetRedirectCallback', hHttpSetting);
  X.Register(H, $9668864C, 'sceHttpSetRecvBlockSize', hHttpSetting);
  X.Register(H, $C98CBBA7, 'sceHttpSetResHeaderMaxSize', hHttpSetting);
  X.Register(H, $C6330B0D, 'sceHttpChangeHttpVersion', hHttpSetting);
  X.Register(H, $A6800C34, 'sceHttpInitCache', hZero);
  X.Register(H, $78B54C09, 'sceHttpEndCache', hZero);
  X.Register(H, $1CEDB9D4, 'sceHttpFlushCache', hZero);
  X.Register(H, $F1657B22, 'sceHttpLoadSystemCookie', hZero);
  X.Register(H, $76D1363B, 'sceHttpSaveSystemCookie', hZero);
  X.Register(H, $E4D21302, 'sceHttpsInit', hZero);
  X.Register(H, $68AB0F86, 'sceHttpsInitWithPath', hZero);
  X.Register(H, $F9D8EB63, 'sceHttpsEnd', hZero);
  X.Register(H, $87797BDD, 'sceHttpsLoadDefaultCert', hZero);

  X.Register(S, $957ECBE2, 'sceSslInit', hZero);
  X.Register(S, $191CDEFF, 'sceSslEnd', hZero);

  X.Register('sceUsb', $AE5DE6AF, 'sceUsbStart', hUsbStart);
  X.Register('sceUsb', $C2464FA0, 'sceUsbStop', hZero);
  X.Register('sceUsb', $586DB82C, 'sceUsbActivate', hUsbActivate);
  X.Register('sceUsb', $C572A9C8, 'sceUsbDeactivate', hUsbDeactivate);
  X.Register('sceUsb', $C21645A4, 'sceUsbGetState', hUsbGetState);
  X.Register('sceUsb', $112CC951, 'sceUsbGetDrvState', hZero);
  X.Register('sceUsb', $4E537366, 'sceUsbGetDrvList', hZero);
  X.Register('sceUsb', $5BE0E002, 'sceUsbWaitState', hUsbWaitState);
  X.Register('sceUsb', $1C360735, 'sceUsbWaitCancel', hZero);

  InetRegister;
  AdhocRegister;
end;

initialization
  RegisterPSPService(TPSPNet);

end.

