unit PSP.SysLibs;

// Small system libraries: UtilsForUser, scePower (and the power and
// volatile memory locks of sceSuspendForUser), sceUmdUser, sceRtc,
// sceImpose, sceHprm, sceDmac and sceOpenPSID.
// Wall-clock time is a fixed epoch plus guest time, so runs repeat exactly.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service, PSP.State.Action;

type
  // The UMD drive state as the threads waiting on it see it (an event flag in the firmware).
  TPSPUmdDrive = class(TPSPKernelObject)
  public
    Waiters: TList<TPSPThread>;
    constructor Create;
    destructor Destroy; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
  end;

  TPSPDate = record
    Year, Month, Day, Hour, Minute, Second: Cardinal;
    Microsecond: Cardinal;
  end;

  TPSPSysLibs = class(TPSPService)
  private
    FUmdCallback: Cardinal;
    FUmdActivated: Boolean;
    FUmd: TPSPUmdDrive;
    FUmdTimeout: Cardinal;
    FPowerCallbacks: array[0..15] of Cardinal;
    // The volatile memory (the upper 4 MB of user RAM) and who waits for it, in order.
    FVolatileLocked: Boolean;
    FVolatileWaiters: TList<TPSPThread>;
    // PLL = 1332 / FPllN MHz, CPU = PLL * FCpuK / 511.
    FPllN: Integer;
    FCpuK: Integer;
    FDmacUntil: Int64;
    function EpochTicks: UInt64;
    function NowTicks: UInt64;
    function LocalOffsetTicks: Int64;
    procedure WriteDate(Address: Cardinal; Ticks: UInt64);
    function ReadDate(Address: Cardinal): TPSPDate;
    function ReadTick(Address: Cardinal): UInt64;
    procedure WriteTick(Address: Cardinal; Ticks: UInt64);
    function PllFloat: Single;
    function CpuFloat: Single;
    function BusFloat: Single;
    procedure ApplyCpuClock;
    function UmdStat: Cardinal;
    procedure UmdChanged(Arg: Cardinal);
    function UmdRetry(T: TPSPThread): Boolean;
    function UmdSatisfiedRetry(T: TPSPThread): Boolean;
    procedure UmdWait(AllowCB, HasTimer: Boolean);
    function UmdDriveArgs(Mode, Drive: Cardinal): Boolean;
    procedure CallKernel(const Lib: string; NID: Cardinal);
    // Utils
    procedure hDcacheNop;
    procedure hDcacheWritebackRange;
    procedure hDcacheInvalidateRange;
    procedure hLibcTime;
    procedure hKernelMemset;
    procedure hKernelMemcpy;
    procedure hLibcGettimeofday;
    procedure hLibcClock;
    procedure hMd5Digest;
    procedure hMd5BlockInit;
    procedure hMd5BlockUpdate;
    procedure hMd5BlockResult;
    procedure hSha1Digest;
    procedure hSha1BlockInit;
    procedure hSha1BlockUpdate;
    procedure hSha1BlockResult;
    procedure hMt19937Init;
    procedure hMt19937UInt;
    procedure hGetGPI;
    // Power
    procedure hPowerGetCpu;
    procedure hPowerGetBus;
    procedure hPowerGetPll;
    procedure hPowerGetCpuFloat;
    procedure hPowerGetBusFloat;
    procedure hPowerGetPllFloat;
    procedure hPowerSetClock;
    procedure hPowerSetCpu;
    procedure hPowerSetBus;
    procedure hPowerRegisterCallback;
    procedure hPowerUnregisterCallback;
    procedure hPowerBatteryPercent;
    procedure hPowerOne;
    procedure hPowerZero;
    procedure hPowerBatteryLifeTime;
    procedure hPowerBatteryTemp;
    procedure hPowerBatteryVolt;
    procedure hPowerVolatileLock;
    procedure hPowerVolatileTryLock;
    procedure hPowerVolatileUnlock;
    procedure hKernelPowerLock;
    procedure hKernelPowerTick;
    procedure VolatileGrant(Ptr, SizePtr: Cardinal);
    procedure VolatileAbort(T: TPSPThread);
    procedure hVolatileMemLock;
    procedure hVolatileMemTryLock;
    procedure hVolatileMemUnlock;
    // UMD
    procedure hUmdActivate;
    procedure hUmdDeactivate;
    procedure hUmdGetDriveStat;
    procedure hUmdCheckMedium;
    procedure hUmdWaitDriveStat;
    procedure hUmdWaitDriveStatWithTimer;
    procedure hUmdWaitDriveStatCB;
    procedure hUmdCancelWaitDriveStat;
    procedure hUmdRegisterCallback;
    procedure hUmdUnregisterCallback;
    procedure hUmdGetDiscInfo;
    procedure hUmdZero;
    // RTC
    procedure hRtcGetCurrentTick;
    procedure hRtcGetTickResolution;
    procedure hRtcGetCurrentClock;
    procedure hRtcGetCurrentClockLocalTime;
    procedure hRtcConvertUtcToLocal;
    procedure hRtcConvertLocalToUtc;
    procedure hRtcGetTick;
    procedure hRtcSetTick;
    procedure hRtcTickAddTicks;
    procedure hRtcTickAddMicroseconds;
    procedure hRtcTickAddSeconds;
    procedure hRtcTickAddMinutes;
    procedure hRtcTickAddHours;
    procedure hRtcTickAddDays;
    procedure hRtcTickAddWeeks;
    procedure hRtcTickAddMonths;
    procedure hRtcTickAddYears;
    procedure hRtcCompareTick;
    procedure hRtcGetDaysInMonth;
    procedure hRtcGetDayOfWeek;
    procedure hRtcIsLeapYear;
    procedure hRtcCheckValid;
    procedure hRtcGetTime_t;
    procedure hRtcSetTime_t;
    procedure hRtcGetTime64_t;
    procedure hRtcSetTime64_t;
    procedure hRtcGetDosTime;
    procedure hRtcSetDosTime;
    procedure hRtcGetWin32FileTime;
    procedure hRtcSetWin32FileTime;
    procedure hRtcGetAccumulativeTime;
    procedure hRtcFormatRFC2822;
    procedure hRtcFormatRFC2822Local;
    procedure hRtcFormatRFC3339;
    procedure hRtcFormatRFC3339Local;
    procedure hRtcParseDateTime;
    procedure hRtcGetLastTime;
    procedure TickAdd(Units: UInt64; Count: UInt64);
    procedure TickAddMonths(Months: Int64);
    // Impose, Hprm, Dmac, misc
    procedure hImposeGetLanguageMode;
    procedure hImposeGetBatteryIconStatus;
    procedure hImposeZero;
    procedure hImposeGetHomePopup;
    procedure hHprmZero;
    procedure hDmacMemcpy;
    procedure hDmacTryMemcpy;
    procedure DmacCopy(TryOnly: Boolean);
    procedure StateDmacDone(Action: TPSPStateAction; Value: Cardinal);
    procedure hGetPSID;
    procedure hZero;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

// Calendar on the proleptic Gregorian calendar; days count from 0001-01-01.
function PSPDaysFromCivil(Y, M, D: Int64): Int64;

procedure PSPCivilFromDays(Days: Int64; out Y, M, D: Int64);

function PSPIsLeapYear(Y: Int64): Boolean;

function PSPDaysInMonth(Y, M: Int64): Integer;
// 0 when the date is valid, else -1 (year) .. -7 (microseconds) for the first bad field.

function PSPCheckDate(const D: TPSPDate): Integer;

function PSPDateToTicks(const D: TPSPDate): UInt64;

function PSPTicksToDate(Ticks: UInt64): TPSPDate;

const
  PSPTicksPerDay: UInt64 = 86400000000;
  PSPUnixEpochTicks: UInt64 = 62135596800000000;

implementation

uses
  System.Math, PSP.Settings;

{ PSP.SysLibs: MD5, SHA-1 and MT19937 with their state in guest memory, as
  UtilsForUser keeps it: h[] at 0, remaining byte count (u16) at 20, total
  length (u64) at 24, the partial block at 32. MD5 runs every byte through the
  block buffer; SHA-1 hashes whole blocks straight from the input. }

const
  Md5Sines: array[0..63] of Cardinal = (
    $D76AA478, $E8C7B756, $242070DB, $C1BDCEEE, $F57C0FAF, $4787C62A, $A8304613, $FD469501,
    $698098D8, $8B44F7AF, $FFFF5BB1, $895CD7BE, $6B901122, $FD987193, $A679438E, $49B40821,
    $F61E2562, $C040B340, $265E5A51, $E9B6C7AA, $D62F105D, $02441453, $D8A1E681, $E7D3FBC8,
    $21E1CDE6, $C33707D6, $F4D50D87, $455A14ED, $A9E3E905, $FCEFA3F8, $676F02D9, $8D2A4C8A,
    $FFFA3942, $8771F681, $6D9D6122, $FDE5380C, $A4BEEA44, $4BDECFA9, $F6BB4B60, $BEBFBC70,
    $289B7EC6, $EAA127FA, $D4EF3085, $04881D05, $D9D4D039, $E6DB99E5, $1FA27CF8, $C4AC5665,
    $F4292244, $432AFF97, $AB9423A7, $FC93A039, $655B59C3, $8F0CCC92, $FFEFF47D, $85845DD1,
    $6FA87E4F, $FE2CE6E0, $A3014314, $4E0811A1, $F7537E82, $BD3AF235, $2AD7D2BB, $EB86D391);
  Md5Shifts: array[0..15] of Byte = (7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21);
  HashInitState: array[0..4] of Cardinal = ($67452301, $EFCDAB89, $98BADCFE, $10325476, $C3D2E1F0);

function RotL(X: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (X shl N) or (X shr (32 - N));
end;

type
  THashKind = (hkMd5, hkSha1);

  THashCtx = record
    Kind: THashKind;
    H: array[0..4] of Cardinal;
    Remains: Cardinal;
    Total: UInt64;
    Buf: array[0..63] of Byte;
    procedure Init(AKind: THashKind);
    procedure Block(P: PByte);
    procedure Update(P: PByte; Size: Cardinal);
    function Final: TBytes;
    procedure Load(M: TPSPMemory; Address: Cardinal; AKind: THashKind);
    procedure Store(M: TPSPMemory; Address: Cardinal);
  end;

procedure THashCtx.Init(AKind: THashKind);
begin
  Kind := AKind;
  Move(HashInitState, H, SizeOf(H));
  Remains := 0;
  Total := 0;
  FillChar(Buf, SizeOf(Buf), 0);
end;

procedure THashCtx.Block(P: PByte);
begin
  if Kind = hkMd5 then
  begin
    var X: array[0..15] of Cardinal;
    for var I := 0 to 15 do
      X[I] := P[I * 4] or (Cardinal(P[I * 4 + 1]) shl 8) or (Cardinal(P[I * 4 + 2]) shl 16) or (Cardinal(P[I * 4 +
            3]) shl 24);
    var A := H[0];
    var B := H[1];
    var C := H[2];
    var D := H[3];
    for var I := 0 to 63 do
    begin
      var F: Cardinal;
      var G: Integer;
      case I shr 4 of
        0:
          begin
            F := (B and C) or (not B and D);
            G := I;
          end;
        1:
          begin
            F := (D and B) or (not D and C);
            G := (5 * I + 1) and 15;
          end;
        2:
          begin
            F := B xor C xor D;
            G := (3 * I + 5) and 15;
          end;
      else
        begin
          F := C xor (B or not D);
          G := (7 * I) and 15;
        end;
      end;
      var T := D;
      D := C;
      C := B;
      B := B + RotL(A + F + Md5Sines[I] + X[G], Md5Shifts[(I shr 4) * 4 + (I and 3)]);
      A := T;
    end;
    Inc(H[0], A);
    Inc(H[1], B);
    Inc(H[2], C);
    Inc(H[3], D);
  end
  else
  begin
    var W: array[0..79] of Cardinal;
    for var I := 0 to 15 do
      W[I] := (Cardinal(P[I * 4]) shl 24) or (Cardinal(P[I * 4 + 1]) shl 16) or (Cardinal(P[I * 4 + 2]) shl 8) or
        P[I * 4 + 3];
    for var I := 16 to 79 do
      W[I] := RotL(W[I - 3] xor W[I - 8] xor W[I - 14] xor W[I - 16], 1);
    var A := H[0];
    var B := H[1];
    var C := H[2];
    var D := H[3];
    var E := H[4];
    for var I := 0 to 79 do
    begin
      var F, K: Cardinal;
      case I div 20 of
        0:
          begin
            F := (B and C) or (not B and D);
            K := $5A827999;
          end;
        1:
          begin
            F := B xor C xor D;
            K := $6ED9EBA1;
          end;
        2:
          begin
            F := (B and C) or (B and D) or (C and D);
            K := $8F1BBCDC;
          end;
      else
        begin
          F := B xor C xor D;
          K := $CA62C1D6;
        end;
      end;
      var T := RotL(A, 5) + F + E + K + W[I];
      E := D;
      D := C;
      C := RotL(B, 30);
      B := A;
      A := T;
    end;
    Inc(H[0], A);
    Inc(H[1], B);
    Inc(H[2], C);
    Inc(H[3], D);
    Inc(H[4], E);
  end;
end;

procedure THashCtx.Update(P: PByte; Size: Cardinal);
begin
  Inc(Total, Size);
  if (Kind = hkSha1) and (Remains = 0) then
    while Size >= 64 do
    begin
      Block(P);
      Inc(P, 64);
      Dec(Size, 64);
    end;
  while Size > 0 do
  begin
    var N := Min(64 - Remains, Size);
    Move(P^, Buf[Remains], N);
    Inc(Remains, N);
    Inc(P, N);
    Dec(Size, N);
    if Remains = 64 then
    begin
      Block(@Buf[0]);
      Remains := 0;
      if Kind = hkSha1 then
        while Size >= 64 do
        begin
          Block(P);
          Inc(P, 64);
          Dec(Size, 64);
        end;
    end;
  end;
end;

function THashCtx.Final: TBytes;
begin
  var Bits := Total * 8;
  var Tail: array[0..127] of Byte;
  FillChar(Tail, SizeOf(Tail), 0);
  Move(Buf[0], Tail[0], Remains);
  Tail[Remains] := $80;
  var Len := 64;
  if Remains >= 56 then
    Len := 128;
  for var I := 0 to 7 do
    if Kind = hkMd5 then
      Tail[Len - 8 + I] := Byte(Bits shr (8 * I))
    else
      Tail[Len - 1 - I] := Byte(Bits shr (8 * I));
  Block(@Tail[0]);
  if Len = 128 then
    Block(@Tail[64]);
  if Kind = hkMd5 then
  begin
    SetLength(Result, 16);
    Move(H[0], Result[0], 16);
  end
  else
  begin
    SetLength(Result, 20);
    for var I := 0 to 4 do
    begin
      Result[I * 4] := Byte(H[I] shr 24);
      Result[I * 4 + 1] := Byte(H[I] shr 16);
      Result[I * 4 + 2] := Byte(H[I] shr 8);
      Result[I * 4 + 3] := Byte(H[I]);
    end;
  end;
end;

procedure THashCtx.Load(M: TPSPMemory; Address: Cardinal; AKind: THashKind);
begin
  Kind := AKind;
  for var I := 0 to 4 do
    H[I] := M.Read32(Address + Cardinal(I) * 4);
  Remains := M.Read16(Address + 20) and 63;
  Total := UInt64(M.Read32(Address + 24)) or (UInt64(M.Read32(Address + 28)) shl 32);
  M.ReadBytes(Address + 32, Buf[0], 64);
end;

procedure THashCtx.Store(M: TPSPMemory; Address: Cardinal);
begin
  var N := 4;
  if Kind = hkSha1 then
    N := 5;
  for var I := 0 to N - 1 do
    M.Write32(Address + Cardinal(I) * 4, H[I]);
  M.Write16(Address + 20, Remains);
  M.Write32(Address + 24, Cardinal(Total));
  M.Write32(Address + 28, Cardinal(Total shr 32));
  // Bytes never stashed are written back unchanged.
  M.WriteBytes(Address + 32, Buf[0], 64);
end;

function GuestBytes(M: TPSPMemory; Address, Size: Cardinal): TBytes;
begin
  SetLength(Result, Size);
  if Size > 0 then
    M.ReadBytes(Address, Result[0], Size);
end;

procedure HashOneShot(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var Data := GuestBytes(M, H.Arg(0), H.Arg(1));
  var C: THashCtx;
  C.Init(Kind);
  if Length(Data) > 0 then
    C.Update(@Data[0], Length(Data));
  var D := C.Final;
  M.WriteBytes(H.Arg(2), D[0], Length(D));
  H.Result(0);
end;

procedure HashBlockInit(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var P := H.Arg(0);
  if P = 0 then
  begin
    H.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var N := 4;
  if Kind = hkSha1 then
    N := 5;
  for var I := 0 to N - 1 do
    M.Write32(P + Cardinal(I) * 4, HashInitState[I]);
  M.Write16(P + 20, 0);
  M.Write16(P + 22, 0);
  M.Write32(P + 24, 0);
  M.Write32(P + 28, 0);
  H.Result(0);
end;

procedure HashBlockUpdate(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var P := H.Arg(0);
  if P = 0 then
  begin
    H.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var C: THashCtx;
  C.Load(M, P, Kind);
  var Data := GuestBytes(M, H.Arg(1), H.Arg(2));
  if Length(Data) > 0 then
    C.Update(@Data[0], Length(Data));
  C.Store(M, P);
  H.Result(0);
end;

procedure HashBlockResult(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var P := H.Arg(0);
  if (P = 0) or (H.Arg(1) = 0) then
  begin
    H.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var C: THashCtx;
  C.Load(M, P, Kind);
  var D := C.Final;
  M.WriteBytes(H.Arg(1), D[0], Length(D));
  H.Result(0);
end;

procedure TPSPSysLibs.hMd5Digest;
begin
  HashOneShot(Self, hkMd5);
end;

procedure TPSPSysLibs.hSha1Digest;
begin
  HashOneShot(Self, hkSha1);
end;

procedure TPSPSysLibs.hMd5BlockInit;
begin
  HashBlockInit(Self, hkMd5);
end;

procedure TPSPSysLibs.hMd5BlockUpdate;
begin
  HashBlockUpdate(Self, hkMd5);
end;

procedure TPSPSysLibs.hMd5BlockResult;
begin
  HashBlockResult(Self, hkMd5);
end;

procedure TPSPSysLibs.hSha1BlockInit;
begin
  HashBlockInit(Self, hkSha1);
end;

procedure TPSPSysLibs.hSha1BlockUpdate;
begin
  HashBlockUpdate(Self, hkSha1);
end;

procedure TPSPSysLibs.hSha1BlockResult;
begin
  HashBlockResult(Self, hkSha1);
end;

{ MT19937: count at 0, then the 624-word state. Init twists the seeded array
  once; each draw returns a word and twists that word in place for the next
  round, which yields the reference sequence. }

procedure TPSPSysLibs.hMt19937Init;
begin
  var Ctx := FHLE.Arg(0);
  var MT: array[0..623] of Cardinal;
  MT[0] := FHLE.Arg(1);
  for var I := 1 to 623 do
    MT[I] := Cardinal(1812433253 * (MT[I - 1] xor (MT[I - 1] shr 30)) + Cardinal(I));
  for var I := 0 to 623 do
  begin
    var Y := (MT[I] and $80000000) or (MT[(I + 1) mod 624] and $7FFFFFFF);
    var V := MT[(I + 397) mod 624] xor (Y shr 1);
    if (Y and 1) <> 0 then
      V := V xor $9908B0DF;
    MT[I] := V;
  end;
  FMemory.Write32(Ctx, 0);
  for var I := 0 to 623 do
    FMemory.Write32(Ctx + 4 + Cardinal(I) * 4, MT[I]);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hMt19937UInt;
begin
  var Ctx := FHLE.Arg(0);
  var Index := FMemory.Read32(Ctx) mod 624;
  var State := Ctx + 4;
  var Y := FMemory.Read32(State + Index * 4);
  var Z := (Y and $80000000) or (FMemory.Read32(State + ((Index + 1) mod 624) * 4) and $7FFFFFFF);
  var V := FMemory.Read32(State + ((Index + 397) mod 624) * 4) xor (Z shr 1);
  if (Z and 1) <> 0 then
    V := V xor $9908B0DF;
  FMemory.Write32(State + Index * 4, V);
  FMemory.Write32(Ctx, (Index + 1) mod 624);
  Y := Y xor (Y shr 11);
  Y := Y xor ((Y shl 7) and $9D2C5680);
  Y := Y xor ((Y shl 15) and $EFC60000);
  Y := Y xor (Y shr 18);
  FHLE.Result(Y);
end;

{ PSP.SysLibs: sceRtc. Ticks are microseconds since 0001-01-01 00:00:00 on the
  proleptic Gregorian calendar; arithmetic wraps at 64 bits like the
  firmware's, and the year field of a date is 16 bits. }

const
  DaysTo1970 = 719162;
  TicksPerSec = 1000000;
  WeekDayNames: array[0..6] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  WeekDayLong: array[0..6] of string = ('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday');
  MonthNames: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
    'Nov', 'Dec');

function PSPDaysFromCivil(Y, M, D: Int64): Int64;
begin
  if M <= 2 then
    Dec(Y);
  var Era: Int64;
  if Y >= 0 then
    Era := Y div 400
  else
    Era := (Y - 399) div 400;
  var Yoe := Y - Era * 400;
  var Doy := (153 * ((M + 9) mod 12) + 2) div 5 + D - 1;
  var Doe := Yoe * 365 + Yoe div 4 - Yoe div 100 + Doy;
  Result := Era * 146097 + Doe - 719468 + DaysTo1970;
end;

procedure PSPCivilFromDays(Days: Int64; out Y, M, D: Int64);
begin
  var Z := Days - DaysTo1970 + 719468;
  var Era: Int64;
  if Z >= 0 then
    Era := Z div 146097
  else
    Era := (Z - 146096) div 146097;
  var Doe := Z - Era * 146097;
  var Yoe := (Doe - Doe div 1460 + Doe div 36524 - Doe div 146096) div 365;
  Y := Yoe + Era * 400;
  var Doy := Doe - (365 * Yoe + Yoe div 4 - Yoe div 100);
  var Mp := (5 * Doy + 2) div 153;
  D := Doy - (153 * Mp + 2) div 5 + 1;
  if Mp < 10 then
    M := Mp + 3
  else
    M := Mp - 9;
  if M <= 2 then
    Inc(Y);
end;

function PSPIsLeapYear(Y: Int64): Boolean;
begin
  Result := ((Y mod 4 = 0) and (Y mod 100 <> 0)) or (Y mod 400 = 0);
end;

function PSPDaysInMonth(Y, M: Int64): Integer;
const
  Days: array[1..12] of Integer = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  if (M < 1) or (M > 12) then
    Exit(0);
  Result := Days[M];
  if (M = 2) and PSPIsLeapYear(Y) then
    Result := 29;
end;

function PSPCheckDate(const D: TPSPDate): Integer;
begin
  if (D.Year < 1) or (D.Year > 9999) then
    Exit(-1);
  if (D.Month < 1) or (D.Month > 12) then
    Exit(-2);
  if (D.Day < 1) or (Integer(D.Day) > PSPDaysInMonth(D.Year, D.Month)) then
    Exit(-3);
  if D.Hour > 23 then
    Exit(-4);
  if D.Minute > 59 then
    Exit(-5);
  if D.Second > 59 then
    Exit(-6);
  if D.Microsecond >= 1000000 then
    Exit(-7);
  Result := 0;
end;

function PSPDateToTicks(const D: TPSPDate): UInt64;
begin
  Result := UInt64(PSPDaysFromCivil(D.Year, D.Month, D.Day)) * PSPTicksPerDay + UInt64(D.Hour) * 3600000000 +
    UInt64(D.Minute) * 60000000 + UInt64(D.Second) * TicksPerSec + D.Microsecond;
end;

function PSPTicksToDate(Ticks: UInt64): TPSPDate;
begin
  var Y, M, D: Int64;
  PSPCivilFromDays(Int64(Ticks div PSPTicksPerDay), Y, M, D);
  var Rem := Ticks mod PSPTicksPerDay;
  Result.Year := Cardinal(Y) and $FFFF;
  Result.Month := M;
  Result.Day := D;
  Result.Hour := Rem div 3600000000;
  Result.Minute := (Rem div 60000000) mod 60;
  Result.Second := (Rem div TicksPerSec) mod 60;
  Result.Microsecond := Rem mod TicksPerSec;
end;

function TicksWeekDay(Ticks: UInt64): Integer;
begin
  // 0001-01-01 was a Monday.
  Result := Integer((Ticks div PSPTicksPerDay + 1) mod 7);
end;

function TPSPSysLibs.EpochTicks: UInt64;
begin
  // 2026-01-01 00:00:00 UTC.
  Result := UInt64(PSPDaysFromCivil(2026, 1, 1)) * PSPTicksPerDay;
end;

function TPSPSysLibs.NowTicks: UInt64;
begin
  Result := EpochTicks + UInt64(FKernel.NowUs);
end;

function TPSPSysLibs.LocalOffsetTicks: Int64;
begin
  Result := Int64(PSPSettings.Timezone + 60 * PSPSettings.DaylightSaving) * 60000000;
end;

procedure TPSPSysLibs.WriteDate(Address: Cardinal; Ticks: UInt64);
begin
  var D := PSPTicksToDate(Ticks);
  FMemory.Write16(Address, D.Year);
  FMemory.Write16(Address + 2, D.Month);
  FMemory.Write16(Address + 4, D.Day);
  FMemory.Write16(Address + 6, D.Hour);
  FMemory.Write16(Address + 8, D.Minute);
  FMemory.Write16(Address + 10, D.Second);
  FMemory.Write32(Address + 12, D.Microsecond);
end;

function TPSPSysLibs.ReadDate(Address: Cardinal): TPSPDate;
begin
  Result.Year := FMemory.Read16(Address);
  Result.Month := FMemory.Read16(Address + 2);
  Result.Day := FMemory.Read16(Address + 4);
  Result.Hour := FMemory.Read16(Address + 6);
  Result.Minute := FMemory.Read16(Address + 8);
  Result.Second := FMemory.Read16(Address + 10);
  Result.Microsecond := FMemory.Read32(Address + 12);
end;

function TPSPSysLibs.ReadTick(Address: Cardinal): UInt64;
begin
  Result := UInt64(FMemory.Read32(Address)) or (UInt64(FMemory.Read32(Address + 4)) shl 32);
end;

procedure TPSPSysLibs.WriteTick(Address: Cardinal; Ticks: UInt64);
begin
  FMemory.Write32(Address, Cardinal(Ticks));
  FMemory.Write32(Address + 4, Cardinal(Ticks shr 32));
end;

procedure TPSPSysLibs.hRtcGetCurrentTick;
begin
  WriteTick(FHLE.Arg(0), NowTicks);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTickResolution;
begin
  FHLE.Result(TicksPerSec);
end;

procedure TPSPSysLibs.hRtcGetCurrentClock;
begin
  WriteDate(FHLE.Arg(0), UInt64(Int64(NowTicks) + Int64(FHLE.ArgInt(1)) * 60000000));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetCurrentClockLocalTime;
begin
  WriteDate(FHLE.Arg(0), UInt64(Int64(NowTicks) + LocalOffsetTicks));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcConvertUtcToLocal;
begin
  WriteTick(FHLE.Arg(1), UInt64(Int64(ReadTick(FHLE.Arg(0))) + LocalOffsetTicks));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcConvertLocalToUtc;
begin
  WriteTick(FHLE.Arg(1), UInt64(Int64(ReadTick(FHLE.Arg(0))) - LocalOffsetTicks));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTick;
begin
  var D := ReadDate(FHLE.Arg(0));
  // The microseconds are added as they are, without a range check.
  var V := PSPCheckDate(D);
  if (V <> 0) and (V <> -7) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  WriteTick(FHLE.Arg(1), PSPDateToTicks(D));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTick;
begin
  WriteDate(FHLE.Arg(0), ReadTick(FHLE.Arg(1)));
  FHLE.Result(0);
end;

// Tick arithmetic is modulo 2^64, including negative counts.
{$Q-}
procedure TPSPSysLibs.TickAdd(Units: UInt64; Count: UInt64);
begin
  WriteTick(FHLE.Arg(0), ReadTick(FHLE.Arg(1)) + Count * Units);
  FHLE.Result(0);
end;
{$IFDEF PSP_CHECKED}{$Q+}{$ENDIF}

procedure TPSPSysLibs.hRtcTickAddTicks;
begin
  TickAdd(1, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddMicroseconds;
begin
  TickAdd(1, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddSeconds;
begin
  TickAdd(TicksPerSec, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddMinutes;
begin
  TickAdd(60000000, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddHours;
begin
  TickAdd(3600000000, UInt64(Int64(FHLE.ArgInt(2))));
end;

procedure TPSPSysLibs.hRtcTickAddDays;
begin
  TickAdd(PSPTicksPerDay, UInt64(Int64(FHLE.ArgInt(2))));
end;

procedure TPSPSysLibs.hRtcTickAddWeeks;
begin
  TickAdd(7 * PSPTicksPerDay, UInt64(Int64(FHLE.ArgInt(2))));
end;

procedure TPSPSysLibs.TickAddMonths(Months: Int64);
begin
  var T := ReadTick(FHLE.Arg(1));
  var Y, M, D: Int64;
  PSPCivilFromDays(Int64(T div PSPTicksPerDay), Y, M, D);
  var Index := Y * 12 + (M - 1) + Months;
  var NY := Index div 12;
  var NM := Index mod 12 + 1;
  if Index < 0 then
  begin
    NY := (Index - 11) div 12;
    NM := Index - NY * 12 + 1;
  end;
  FHLE.Result(0);
  // A result outside years 1..9999 leaves the destination as it was.
  if (NY < 1) or (NY > 9999) then
    Exit;
  var Last := PSPDaysInMonth(NY, NM);
  if D > Last then
    D := Last;
  WriteTick(FHLE.Arg(0), UInt64(PSPDaysFromCivil(NY, NM, D)) * PSPTicksPerDay + T mod PSPTicksPerDay);
end;

procedure TPSPSysLibs.hRtcTickAddMonths;
begin
  TickAddMonths(FHLE.ArgInt(2));
end;

procedure TPSPSysLibs.hRtcTickAddYears;
begin
  TickAddMonths(Int64(FHLE.ArgInt(2)) * 12);
end;

procedure TPSPSysLibs.hRtcCompareTick;
begin
  var A := ReadTick(FHLE.Arg(0));
  var B := ReadTick(FHLE.Arg(1));
  if A < B then
    FHLE.Result($FFFFFFFF)
  else if A > B then
    FHLE.Result(1)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetDaysInMonth;
begin
  var Y := FHLE.ArgInt(0);
  var M := FHLE.ArgInt(1);
  if (M < 1) or (M > 12) or (Y < 1) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX);
    Exit;
  end;
  FHLE.Result(Cardinal(PSPDaysInMonth(Y, M)));
end;

procedure TPSPSysLibs.hRtcGetDayOfWeek;
const
  T: array[1..12] of Integer = (0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4);
begin
  var Y := FHLE.ArgInt(0);
  var M := FHLE.ArgInt(1);
  var D := FHLE.ArgInt(2);
  // Sakamoto's method; the day is not range checked. Months outside 1..12 index
  // past the firmware's table: these are the words found there.
  var Off: Integer;
  if (M >= 1) and (M <= 12) then
    Off := T[M]
  else
    case M of
      0:
        Off := 1;
      573:
        Off := 0;
      1024:
        Off := 4;
      4587:
        Off := 6;
    else
      Off := 0;
    end;
  if (M = 1) or (M = 2) then
    Dec(Y);
  var R := (Int64(Y) + Y div 4 - Y div 100 + Y div 400 + Off + D) mod 7;
  if R < 0 then
    Inc(R, 7);
  FHLE.Result(Cardinal(R));
end;

procedure TPSPSysLibs.hRtcIsLeapYear;
begin
  FHLE.Result(Ord(PSPIsLeapYear(FHLE.ArgInt(0))));
end;

procedure TPSPSysLibs.hRtcCheckValid;
begin
  FHLE.Result(Cardinal(PSPCheckDate(ReadDate(FHLE.Arg(0)))));
end;

procedure TPSPSysLibs.hRtcGetTime_t;
begin
  var T := PSPDateToTicks(ReadDate(FHLE.Arg(0)));
  FMemory.Write32(FHLE.Arg(1), Cardinal(Int64(T - PSPUnixEpochTicks) div TicksPerSec));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTime_t;
begin
  WriteDate(FHLE.Arg(0), PSPUnixEpochTicks + UInt64(FHLE.Arg(1)) * TicksPerSec);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTime64_t;
begin
  var T := PSPDateToTicks(ReadDate(FHLE.Arg(0)));
  WriteTick(FHLE.Arg(1), UInt64(Int64(T - PSPUnixEpochTicks) div TicksPerSec));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTime64_t;
begin
  WriteDate(FHLE.Arg(0), PSPUnixEpochTicks + FHLE.Arg64(2) * TicksPerSec);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetDosTime;
begin
  var D := ReadDate(FHLE.Arg(0));
  if (D.Year < 1980) or (D.Year > 2107) then
  begin
    FHLE.Result($FFFFFFFF);
    Exit;
  end;
  var V := ((D.Year - 1980) shl 25) or ((D.Month and 15) shl 21) or ((D.Day and 31) shl 16) or
    ((D.Hour and 31) shl 11) or ((D.Minute and 63) shl 5) or ((D.Second shr 1) and 31);
  FMemory.Write32(FHLE.Arg(1), V);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetDosTime;
begin
  var P := FHLE.Arg(0);
  var V := FHLE.Arg(1);
  FMemory.Write16(P, 1980 + (V shr 25));
  FMemory.Write16(P + 2, (V shr 21) and 15);
  FMemory.Write16(P + 4, (V shr 16) and 31);
  FMemory.Write16(P + 6, (V shr 11) and 31);
  FMemory.Write16(P + 8, (V shr 5) and 63);
  FMemory.Write16(P + 10, (V and 31) * 2);
  FMemory.Write32(P + 12, 0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetWin32FileTime;
begin
  var D := ReadDate(FHLE.Arg(0));
  var P := FHLE.Arg(1);
  if P = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  // Only the year is checked: a day past the month's end runs into the next.
  if (D.Year < 1601) or (D.Year > 9999) then
  begin
    WriteTick(P, 0);
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  var Base := UInt64(PSPDaysFromCivil(1601, 1, 1)) * PSPTicksPerDay;
  WriteTick(P, (PSPDateToTicks(D) - Base) * 10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetWin32FileTime;
begin
  var Base := UInt64(PSPDaysFromCivil(1601, 1, 1)) * PSPTicksPerDay;
  WriteDate(FHLE.Arg(0), Base + FHLE.Arg64(2) div 10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetAccumulativeTime;
begin
  FHLE.Result64(NowTicks);
end;

function FormatRFC2822(Ticks: UInt64; TzMinutes: Integer): string;
begin
  var T := UInt64(Int64(Ticks) + Int64(TzMinutes) * 60000000);
  var D := PSPTicksToDate(T);
  var Sign := '+';
  var Tz := TzMinutes;
  if Tz < 0 then
  begin
    Sign := '-';
    Tz := -Tz;
  end;
  var Mon := 'Jan';
  if (D.Month >= 1) and (D.Month <= 12) then
    Mon := MonthNames[D.Month];
  Result := Format('%s, %.2d %s %.4d %.2d:%.2d:%.2d %s%.2d%.2d',
    [WeekDayNames[TicksWeekDay(T)], D.Day, Mon, D.Year, D.Hour, D.Minute, D.Second, Sign, Tz div 60, Tz mod 60]);
end;

function FormatRFC3339(Ticks: UInt64; TzMinutes: Integer): string;
begin
  var T := UInt64(Int64(Ticks) + Int64(TzMinutes) * 60000000);
  var D := PSPTicksToDate(T);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.2d',
    [D.Year, D.Month, D.Day, D.Hour, D.Minute, D.Second, D.Microsecond div 10000]);
  if TzMinutes = 0 then
    Result := Result + 'Z'
  else
  begin
    var Sign := '+';
    var Tz := TzMinutes;
    if Tz < 0 then
    begin
      Sign := '-';
      Tz := -Tz;
    end;
    Result := Result + Format('%s%.2d:%.2d', [Sign, Tz div 60, Tz mod 60]);
  end;
end;

procedure TPSPSysLibs.hRtcFormatRFC2822;
begin
  FMemory.WriteString(FHLE.Arg(0), RawByteString(FormatRFC2822(ReadTick(FHLE.Arg(1)), FHLE.ArgInt(2))), 64);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcFormatRFC2822Local;
begin
  FMemory.WriteString(FHLE.Arg(0),
    RawByteString(FormatRFC2822(ReadTick(FHLE.Arg(1)), LocalOffsetTicks div 60000000)), 64);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcFormatRFC3339;
begin
  FMemory.WriteString(FHLE.Arg(0), RawByteString(FormatRFC3339(ReadTick(FHLE.Arg(1)), FHLE.ArgInt(2))), 64);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcFormatRFC3339Local;
begin
  FMemory.WriteString(FHLE.Arg(0),
    RawByteString(FormatRFC3339(ReadTick(FHLE.Arg(1)), LocalOffsetTicks div 60000000)), 64);
  FHLE.Result(0);
end;

type
  TDateScanner = record
    S: string;
    P: Integer;
    function Done: Boolean;
    function Peek: Char;
    function Take(C: Char): Boolean;
    function Number(MinDigits, MaxDigits: Integer; out V: Integer): Boolean;
    function ReadWord(out W: string): Boolean;
  end;

function TDateScanner.Done: Boolean;
begin
  Result := P > Length(S);
end;

function TDateScanner.Peek: Char;
begin
  if Done then
    Result := #0
  else
    Result := S[P];
end;

function TDateScanner.Take(C: Char): Boolean;
begin
  Result := Peek = C;
  if Result then
    Inc(P);
end;

function TDateScanner.Number(MinDigits, MaxDigits: Integer; out V: Integer): Boolean;
begin
  V := 0;
  var N := 0;
  while (N < MaxDigits) and CharInSet(Peek, ['0'..'9']) do
  begin
    V := V * 10 + Ord(Peek) - Ord('0');
    Inc(P);
    Inc(N);
  end;
  Result := N >= MinDigits;
end;

function TDateScanner.ReadWord(out W: string): Boolean;
begin
  var Start := P;
  while CharInSet(Peek, ['A'..'Z', 'a'..'z']) do
    Inc(P);
  W := Copy(S, Start, P - Start);
  Result := W <> '';
end;

function ParseRFC3339(const Text: string; out Ticks: UInt64): Boolean;
begin
  var Sc: TDateScanner;
  Sc.S := Text;
  Sc.P := 1;
  var D := Default(TPSPDate);
  var Y, Mo, Dd, H, Mi, Se: Integer;
  Result := False;
  if not (Sc.Number(4, 4, Y) and Sc.Take('-') and Sc.Number(2, 2, Mo) and Sc.Take('-') and Sc.Number(2, 2, Dd)) then
    Exit;
  if not (Sc.Take('T') or Sc.Take('t')) then
    Exit;
  if not (Sc.Number(2, 2, H) and Sc.Take(':') and Sc.Number(2, 2, Mi) and Sc.Take(':') and Sc.Number(2, 2, Se)) then
    Exit;
  var Us := 0;
  if Sc.Take('.') then
  begin
    var Scale := 100000;
    var Digits := 0;
    while CharInSet(Sc.Peek, ['0'..'9']) do
    begin
      if Scale > 0 then
        Inc(Us, (Ord(Sc.Peek) - Ord('0')) * Scale);
      Scale := Scale div 10;
      Inc(Sc.P);
      Inc(Digits);
    end;
    if Digits = 0 then
      Exit;
  end;
  var Offset := 0;
  if Sc.Take('Z') or Sc.Take('z') then

  else if CharInSet(Sc.Peek, ['+', '-']) then
  begin
    var Neg := Sc.Peek = '-';
    Inc(Sc.P);
    var OH, OM: Integer;
    if not (Sc.Number(2, 2, OH) and Sc.Take(':') and Sc.Number(2, 2, OM)) then
      Exit;
    Offset := OH * 60 + OM;
    if Neg then
      Offset := -Offset;
  end
  else
    Exit;
  if not Sc.Done then
    Exit;
  D.Year := Y;
  D.Month := Mo;
  D.Day := Dd;
  D.Hour := H;
  D.Minute := Mi;
  D.Second := Se;
  D.Microsecond := Us;
  if PSPCheckDate(D) <> 0 then
    Exit;
  Ticks := UInt64(Int64(PSPDateToTicks(D)) - Int64(Offset) * 60000000);
  Result := True;
end;

function ParseRFC2822(const Text: string; out Ticks: UInt64): Boolean;
begin
  var Sc: TDateScanner;
  Sc.S := Text;
  Sc.P := 1;
  Result := False;
  var W: string;
  if not Sc.ReadWord(W) then
    Exit;
  var Known := False;
  for var I := 0 to 6 do
    if SameText(W, WeekDayNames[I]) or SameText(W, WeekDayLong[I]) then
      Known := True;
  if not Known or not Sc.Take(',') or not Sc.Take(' ') then
    Exit;
  var Dd, Y, H, Mi, Se, Tz: Integer;
  if not Sc.Number(1, 2, Dd) or not Sc.Take(' ') or not Sc.ReadWord(W) or not Sc.Take(' ') then
    Exit;
  var Mo := 0;
  for var I := 1 to 12 do
    if SameText(W, MonthNames[I]) then
      Mo := I;
  if Mo = 0 then
    Exit;
  if not (Sc.Number(4, 4, Y) and Sc.Take(' ') and Sc.Number(2, 2, H) and Sc.Take(':') and Sc.Number(2, 2, Mi) and
    Sc.Take(':') and Sc.Number(2, 2, Se) and Sc.Take(' ')) then
    Exit;
  if not CharInSet(Sc.Peek, ['+', '-']) then
    Exit;
  var Neg := Sc.Peek = '-';
  Inc(Sc.P);
  if not Sc.Number(4, 4, Tz) or not Sc.Done then
    Exit;
  var Offset := (Tz div 100) * 60 + Tz mod 100;
  if Neg then
    Offset := -Offset;
  var D := Default(TPSPDate);
  D.Year := Y;
  D.Month := Mo;
  D.Day := Dd;
  D.Hour := H;
  D.Minute := Mi;
  D.Second := Se;
  if PSPCheckDate(D) <> 0 then
    Exit;
  Ticks := UInt64(Int64(PSPDateToTicks(D)) - Int64(Offset) * 60000000);
  Result := True;
end;

procedure TPSPSysLibs.hRtcParseDateTime;
begin
  var Text := FMemory.ReadString(FHLE.Arg(1), 256);
  var T: UInt64;
  if ParseRFC3339(Text, T) or ParseRFC2822(Text, T) then
  begin
    WriteTick(FHLE.Arg(0), T);
    FHLE.Result(0);
  end
  else
    FHLE.Result($FFFFFFFF);
end;

procedure TPSPSysLibs.hRtcGetLastTime;
begin
  if FHLE.Arg(0) <> 0 then
    WriteTick(FHLE.Arg(0), EpochTicks);
  FHLE.Result(0);
end;

{ PSP.SysLibs: scePower. The PLL runs at 1332/N MHz (N = 4..7); the CPU at
  PLL * K / 511 and the bus at half the PLL, so set frequencies round down to
  those steps. Callbacks hear AC power, a battery present and full charge. }

const
  PowerCallbackInfo = $00001000 or $00000080 or 100;
  SCE_POWER_ERROR_SLOT_BUSY = Cardinal($80000020);
  SCE_POWER_ERROR_NO_SLOT = Cardinal($80000022);
  SCE_POWER_ERROR_KERNEL_SLOT = Cardinal($80000023);
  SCE_POWER_ERROR_NOT_REGISTERED = Cardinal($80000025);

function TPSPSysLibs.PllFloat: Single;
begin
  Result := 1332 / FPllN;
end;

function TPSPSysLibs.CpuFloat: Single;
begin
  var Pll: Single := PllFloat;
  var Scaled: Single := Pll * FCpuK;
  Result := Scaled / 511;
end;

function TPSPSysLibs.BusFloat: Single;
begin
  Result := PllFloat / 2;
end;

procedure TPSPSysLibs.ApplyCpuClock;
begin
  FKernel.NowUs;
  FKernel.Scheduler.MHz := Max(1, Trunc(CpuFloat));
  // The running slice was sized at the old clock.
  FHLE.CPU.Stop;
end;

procedure TPSPSysLibs.hPowerGetCpu;
begin
  FHLE.Result(Cardinal(Trunc(CpuFloat)));
end;

procedure TPSPSysLibs.hPowerGetBus;
begin
  FHLE.Result(Cardinal(Trunc(BusFloat)));
end;

procedure TPSPSysLibs.hPowerGetPll;
begin
  FHLE.Result(Cardinal(Trunc(PllFloat)));
end;

procedure TPSPSysLibs.hPowerGetCpuFloat;
begin
  FHLE.ResultFloat(CpuFloat);
end;

procedure TPSPSysLibs.hPowerGetBusFloat;
begin
  FHLE.ResultFloat(BusFloat);
end;

procedure TPSPSysLibs.hPowerGetPllFloat;
begin
  FHLE.ResultFloat(PllFloat);
end;

procedure TPSPSysLibs.hPowerSetClock;
begin
  var Pll := FHLE.ArgInt(0);
  var Cpu := FHLE.ArgInt(1);
  var Bus := FHLE.ArgInt(2);
  if (Pll < 19) or (Pll > 333) or (Cpu < 1) or (Cpu > 333) or (Bus < 1) or (Bus > 166) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  // The slowest PLL step that reaches the requested frequency.
  var N := 7;
  while (N > 4) and (1332 < Pll * N) do
    Dec(N);
  FPllN := N;
  FCpuK := Min(511, (Cpu * 511 * N) div 1332);
  ApplyCpuClock;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerSetCpu;
begin
  var Cpu := FHLE.ArgInt(0);
  if (Cpu < 1) or (Cpu > Trunc(PllFloat)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  FCpuK := Min(511, (Cpu * 511 * FPllN) div 1332);
  ApplyCpuClock;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerSetBus;
begin
  // The bus follows the PLL; the call only validates.
  var Bus := FHLE.ArgInt(0);
  if (Bus < 1) or (Bus > Trunc(BusFloat)) then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerRegisterCallback;
begin
  var Slot := FHLE.ArgInt(0);
  var CBId := FHLE.Arg(1);
  if (Slot < -1) or (Slot >= 32) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX);
    Exit;
  end;
  if Slot >= 16 then
  begin
    FHLE.Result(SCE_POWER_ERROR_KERNEL_SLOT);
    Exit;
  end;
  var CB := TPSPCallback(FKernel.GetObject(CBId, TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_ID);
    Exit;
  end;
  if Slot = -1 then
  begin
    for var I := 0 to High(FPowerCallbacks) do
      if FPowerCallbacks[I] = 0 then
      begin
        Slot := I;
        Break;
      end;
    if Slot = -1 then
    begin
      FHLE.Result(SCE_POWER_ERROR_NO_SLOT);
      Exit;
    end;
  end
  else if FPowerCallbacks[Slot] <> 0 then
  begin
    FHLE.Result(SCE_POWER_ERROR_SLOT_BUSY);
    Exit;
  end;
  FPowerCallbacks[Slot] := CBId;
  FKernel.NotifyCallback(CB, PowerCallbackInfo);
  FHLE.Result(Cardinal(Slot));
end;

procedure TPSPSysLibs.hPowerUnregisterCallback;
begin
  var Slot := FHLE.ArgInt(0);
  if (Slot < 0) or (Slot >= 32) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX);
    Exit;
  end;
  if Slot >= 16 then
  begin
    FHLE.Result(SCE_POWER_ERROR_KERNEL_SLOT);
    Exit;
  end;
  if FPowerCallbacks[Slot] = 0 then
  begin
    FHLE.Result(SCE_POWER_ERROR_NOT_REGISTERED);
    Exit;
  end;
  FPowerCallbacks[Slot] := 0;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerBatteryPercent;
begin
  FHLE.Result(100);
end;

procedure TPSPSysLibs.hPowerOne;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.hPowerZero;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerBatteryLifeTime;
begin
  FHLE.Result(300);
end;

procedure TPSPSysLibs.hPowerBatteryTemp;
begin
  FHLE.Result(28);
end;

procedure TPSPSysLibs.hPowerBatteryVolt;
begin
  FHLE.Result(4135);
end;

const
  SCE_KERNEL_ERROR_POWER_VMEM_IN_USE = Cardinal($802B0200);

// The volatile memory lock: mode 0 only, waiters served in the order they
// came. A lock that cannot wait still reports where the memory is; unlocking
// it when free answers like a semaphore signalled past its maximum.
procedure TPSPSysLibs.VolatileGrant(Ptr, SizePtr: Cardinal);
begin
  if Ptr <> 0 then
    FMemory.Write32(Ptr, $08400000);
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, $00400000);
end;

procedure TPSPSysLibs.VolatileAbort(T: TPSPThread);
begin
  FVolatileWaiters.Remove(T);
end;

procedure TPSPSysLibs.hVolatileMemLock;
begin
  var Ptr := FHLE.Arg(1);
  var SizePtr := FHLE.Arg(2);
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if FKernel.InInterrupt then
  begin
    VolatileGrant(Ptr, SizePtr);
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    VolatileGrant(Ptr, SizePtr);
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  if not FVolatileLocked then
  begin
    FVolatileLocked := True;
    VolatileGrant(Ptr, SizePtr);
    FHLE.Result(0);
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  var T := FKernel.Current;
  FVolatileWaiters.Add(T);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, VolatileAbort, 'volatile');
  T.Wait.Data[0] := Ptr;
  T.Wait.Data[1] := SizePtr;
end;

procedure TPSPSysLibs.hVolatileMemTryLock;
begin
  if FHLE.Arg(0) <> 0 then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE)
  else if FVolatileLocked then
    FHLE.Result(SCE_KERNEL_ERROR_POWER_VMEM_IN_USE)
  else
  begin
    FVolatileLocked := True;
    VolatileGrant(FHLE.Arg(1), FHLE.Arg(2));
    FHLE.Result(0);
  end;
end;

procedure TPSPSysLibs.hVolatileMemUnlock;
begin
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if not FVolatileLocked then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_SEMA_OVF);
    Exit;
  end;
  FHLE.Result(0);
  // The lock passes to the first thread waiting for it.
  while FVolatileWaiters.Count > 0 do
  begin
    var T := FVolatileWaiters[0];
    FVolatileWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'volatile') then
    begin
      VolatileGrant(T.Wait.Data[0], T.Wait.Data[1]);
      FKernel.EndWait(T, 0);
      Exit;
    end;
  end;
  FVolatileLocked := False;
end;

// scePower's volatile memory calls are the sceSuspend ones under another name.
procedure TPSPSysLibs.hPowerVolatileLock;
begin
  hVolatileMemLock;
end;

procedure TPSPSysLibs.hPowerVolatileTryLock;
begin
  hVolatileMemTryLock;
end;

procedure TPSPSysLibs.hPowerVolatileUnlock;
begin
  hVolatileMemUnlock;
end;

procedure TPSPSysLibs.hKernelPowerLock;
begin
  // Only lock type 0 exists for user code.
  if FHLE.Arg(0) <> 0 then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hKernelPowerTick;
begin
  FHLE.Result(0);
end;

{ TPSPUmdDrive }

constructor TPSPUmdDrive.Create;
begin
  inherited Create;
  Waiters := TList<TPSPThread>.Create;
end;

destructor TPSPUmdDrive.Destroy;
begin
  Waiters.Free;
  inherited;
end;

procedure TPSPUmdDrive.RemoveWaiter(T: TPSPThread);
begin
  Waiters.Remove(T);
end;

procedure TPSPUmdDrive.AddWaiter(T: TPSPThread);
begin
  if not Waiters.Contains(T) then
    Waiters.Add(T);
end;

{ TPSPSysLibs }

constructor TPSPSysLibs.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FUmd := TPSPUmdDrive.Create;
  FUmd.Name := 'SceUmdDriveStat';
  FVolatileWaiters := TList<TPSPThread>.Create;
end;

destructor TPSPSysLibs.Destroy;
begin
  FUmd.Free;
  FVolatileWaiters.Free;
  inherited;
end;

procedure TPSPSysLibs.Reset;
begin
  FDmacUntil := 0;
  FUmdCallback := 0;
  // A game booted from its disc finds the drive activated by the system
  // (Metal Gear Acid 2 waits for READY without activating it).
  FUmdActivated := FSystem.IO.Disc <> nil;
  FUmd.Waiters.Clear;
  FUmd.Kernel := FKernel;
  // A word the kernel reads wait timeouts from (it takes them by pointer).
  FUmdTimeout := FKernel.AllocKernel(16, 'umd timeout');
  FillChar(FPowerCallbacks, SizeOf(FPowerCallbacks), 0);
  FVolatileLocked := False;
  FVolatileWaiters.Clear;
  FPllN := 6;
  FCpuK := 511;
end;

procedure TPSPSysLibs.CallKernel(const Lib: string; NID: Cardinal);
begin
  var F := FHLE.FunctionInfo(FHLE.Find(Lib, NID));
  if (F <> nil) and Assigned(F.Handler) then
    F.Handler()
  else
    FHLE.Result(0);
end;

{ Utils }

procedure TPSPSysLibs.hDcacheNop;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hDcacheWritebackRange;
begin
  // (address, size): only a negative size is refused.
  if Integer(FHLE.Arg(1)) < 0 then
    FHLE.Result($80000104)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hDcacheInvalidateRange;
begin
  // (address, size): the range must stay in user space and cover whole
  // 64-byte lines.
  var P := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  if Size = 0 then
    FHLE.Result(0)
  else if (Integer(Size) < 0) or (P >= $80000000) or (UInt64(P) + Size > $80000000) then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR)
  else if ((P or Size) and 63) <> 0 then
    FHLE.Result($8002044C)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hLibcTime;
begin
  var P := FHLE.Arg(0);
  if (P <> 0) and ((P >= $80000000) or not FMemory.Valid(P, 4)) then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var T := Cardinal((NowTicks - PSPUnixEpochTicks) div 1000000);
  if P <> 0 then
    FMemory.Write32(P, T);
  FHLE.Result(T);
end;

procedure TPSPSysLibs.hKernelMemset;
begin
  var Dst := FHLE.Arg(0);
  var Size := FHLE.ArgInt(2);
  if Size > 0 then
    FMemory.Fill(Dst, FHLE.Arg(1) and $FF, Size);
  FHLE.Result(Dst);
end;

procedure TPSPSysLibs.hKernelMemcpy;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var Size := FHLE.ArgInt(2);
  // A forward byte copy: an overlapping destination repeats the start.
  for var I := 0 to Size - 1 do
    FMemory.Write8(Dst + Cardinal(I), FMemory.Read8(Src + Cardinal(I)));
  FHLE.Result(Dst);
end;

procedure TPSPSysLibs.hLibcGettimeofday;
begin
  var Us := NowTicks - PSPUnixEpochTicks;
  var P := FHLE.Arg(0);
  if P <> 0 then
  begin
    FMemory.Write32(P, Cardinal(Us div 1000000));
    FMemory.Write32(P + 4, Cardinal(Us mod 1000000));
  end;
  if FHLE.Arg(1) <> 0 then
  begin
    FMemory.Write32(FHLE.Arg(1), 0);
    FMemory.Write32(FHLE.Arg(1) + 4, 0);
  end;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hLibcClock;
begin
  FHLE.Result(Cardinal(FKernel.NowUs));
end;

procedure TPSPSysLibs.hGetGPI;
begin
  FHLE.Result(0);
end;

{ Impose, Hprm, Dmac, misc }

procedure TPSPSysLibs.hImposeGetLanguageMode;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), Cardinal(PSPSettings.Language));
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(PSPSettings.ButtonSwap));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hImposeGetBatteryIconStatus;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), 0);
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), 3);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hImposeZero;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hImposeGetHomePopup;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.hHprmZero;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), 0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hDmacMemcpy;
begin
  DmacCopy(False);
end;

procedure TPSPSysLibs.hDmacTryMemcpy;
begin
  DmacCopy(True);
end;

procedure TPSPSysLibs.DmacCopy(TryOnly: Boolean);
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  if Size = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  if (Dst = 0) or (Src = 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER);
    Exit;
  end;
  var Now := FKernel.Scheduler.Now;
  if TryOnly and (FDmacUntil > Now) then
  begin
    FHLE.Result($80000021);
    Exit;
  end;
  if ((Size < 272) and (FDmacUntil <= Now)) or not FKernel.CanWait then
  begin
    FMemory.Copy(Dst, Src, Size);
    FHLE.Result(0);
    Exit;
  end;
  // The short path is polled; longer transfers release the calling thread.
  FDmacUntil := Max(Now, FDmacUntil) + 8000 + Int64(Size) * 10;
  FHLE.Result(0);
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitSema, nil, 0, 0, False, nil, nil, 'dmac');
  FKernel.AddStateTimer(FDmacUntil, T, TPSPStateAction.Create(StateDmacDone, [T], [Dst, Src, Size]));
end;

procedure TPSPSysLibs.StateDmacDone(Action: TPSPStateAction; Value: Cardinal);
begin
  FMemory.Copy(Cardinal(Action.Arg(0)), Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)));
  var T := TPSPThread(Action.Obj(0));
  if T.IsWaiting and (T.Wait.HLETag = 'dmac') then
    FKernel.EndWait(T, 0);
end;

procedure TPSPSysLibs.hGetPSID;
begin
  var P := FHLE.Arg(0);
  for var I := 0 to 15 do
    FMemory.Write8(P + Cardinal(I), Cardinal(I) * 17);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hZero;
begin
  FHLE.Result(0);
end;

{ PSP.SysLibs: sceUmdUser. A disc is always present and initialised; it is
  readable (READY) once activated. Waits are on the drive state, like waits on
  the firmware's event flag; callbacks hear every activate and deactivate. }

const
  UMD_NOT_PRESENT = $01;
  UMD_PRESENT = $02;
  UMD_INITED = $10;
  UMD_READY = $20;
  UMD_WAITABLE = $3B;
  UMD_MIN_TIMEOUT = 200;
  UMD_ERROR_INVALID = SCE_ERROR_ERRNO_EINVAL;

function TPSPSysLibs.UmdStat: Cardinal;
begin
  Result := UMD_PRESENT or UMD_INITED;
  if FUmdActivated then
    Result := Result or UMD_READY;
end;

procedure TPSPSysLibs.UmdChanged(Arg: Cardinal);
begin
  if FUmdCallback <> 0 then
  begin
    var CB := TPSPCallback(FKernel.GetObject(FUmdCallback, TPSPCallback));
    if CB <> nil then
      FKernel.NotifyCallback(CB, Arg);
  end;
  var Stat := UmdStat;
  for var T in FUmd.Waiters.ToArray do
    if (T.Wait.Data[0] and Stat) <> 0 then
      FKernel.EndWait(T, 0);
end;

function TPSPSysLibs.UmdRetry(T: TPSPThread): Boolean;
begin
  Result := (T.Wait.Data[0] and UmdStat) <> 0;
  if Result then
    T.SetResult(0);
end;

function TPSPSysLibs.UmdSatisfiedRetry(T: TPSPThread): Boolean;
begin
  T.SetResult(0);
  Result := True;
end;

function TPSPSysLibs.UmdDriveArgs(Mode, Drive: Cardinal): Boolean;
begin
  Result := ((Mode = 1) or (Mode = 2)) and (Drive <> 0) and (Drive < $80000000) and
    (FMemory.ReadString(Drive, 16) = 'disc0:');
end;

procedure TPSPSysLibs.hUmdActivate;
begin
  if not UmdDriveArgs(FHLE.Arg(0), FHLE.Arg(1)) then
  begin
    FHLE.Result(UMD_ERROR_INVALID);
    Exit;
  end;
  FUmdActivated := True;
  FHLE.Result(0);
  // Programs built for newer firmware hear the full state.
  if FKernel.CompiledSdkVersion = 0 then
    UmdChanged(UMD_PRESENT or UMD_READY)
  else
    UmdChanged(UmdStat);
end;

procedure TPSPSysLibs.hUmdDeactivate;
begin
  if not UmdDriveArgs(FHLE.Arg(0), FHLE.Arg(1)) then
  begin
    FHLE.Result(UMD_ERROR_INVALID);
    Exit;
  end;
  FUmdActivated := False;
  FHLE.Result(0);
  UmdChanged(UmdStat);
end;

procedure TPSPSysLibs.hUmdGetDriveStat;
begin
  FHLE.Result(UmdStat);
end;

procedure TPSPSysLibs.hUmdCheckMedium;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.UmdWait(AllowCB, HasTimer: Boolean);
begin
  var Want := FHLE.Arg(0);
  if (Want and UMD_WAITABLE) = 0 then
  begin
    FHLE.Result(UMD_ERROR_INVALID);
    Exit;
  end;
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  var T := FKernel.Current;
  FHLE.Result(0);
  if (Want and UmdStat) <> 0 then
  begin
    // Already satisfied; the CB variant still runs pending callbacks.
    if AllowCB and T.HasPendingCallbacks then
      FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, True, UmdSatisfiedRetry, nil, 'umd');
    Exit;
  end;
  var TimeoutPtr: Cardinal := 0;
  if HasTimer and (FHLE.Arg(1) <> 0) then
  begin
    FMemory.Write32(FUmdTimeout, Max(FHLE.Arg(1), UMD_MIN_TIMEOUT));
    TimeoutPtr := FUmdTimeout;
  end;
  FUmd.AddWaiter(T);
  FKernel.BeginWait(PSPWaitEventFlag, FUmd, 0, TimeoutPtr, AllowCB, UmdRetry, nil, 'umd');
  T.Wait.Data[0] := Want;
  if (T.Frames.Count > 0) and (T.Wait.Kind = PSPWaitNone) then
  begin
    // Callbacks started first: the wait sits in their frame.
    var F := T.Frames.Last;
    F.SavedWait.Data[0] := Want;
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPSysLibs.hUmdWaitDriveStat;
begin
  UmdWait(False, False);
end;

procedure TPSPSysLibs.hUmdWaitDriveStatWithTimer;
begin
  UmdWait(False, True);
end;

procedure TPSPSysLibs.hUmdWaitDriveStatCB;
begin
  UmdWait(True, True);
end;

procedure TPSPSysLibs.hUmdCancelWaitDriveStat;
begin
  FHLE.Result(0);
  for var T in FUmd.Waiters.ToArray do
    FKernel.EndWait(T, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPSysLibs.hUmdRegisterCallback;
begin
  var CB := TPSPCallback(FKernel.GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(UMD_ERROR_INVALID);
    Exit;
  end;
  FUmdCallback := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdUnregisterCallback;
begin
  var Id := FHLE.Arg(0);
  if Id <> FUmdCallback then
  begin
    FHLE.Result(UMD_ERROR_INVALID);
    Exit;
  end;
  FUmdCallback := 0;
  // Before 3.00 the id comes back.
  if FKernel.CompiledSdkVersion > $3000000 then
    FHLE.Result(0)
  else
    FHLE.Result(Id);
end;

procedure TPSPSysLibs.hUmdGetDiscInfo;
begin
  var P := FHLE.Arg(0);
  if (P = 0) or (P >= $80000000) or (FMemory.Read32(P) <> 8) then
  begin
    FHLE.Result(UMD_ERROR_INVALID);
    Exit;
  end;
  FMemory.Write32(P + 4, $10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdZero;
begin
  FHLE.Result(0);
end;

{ PSP.SysLibs: NID table. }

procedure TPSPSysLibs.Register;
const
  U = 'UtilsForUser';
  P = 'scePower';
  M = 'sceUmdUser';
  R = 'sceRtc';
  I = 'sceImpose';
  S = 'sceSuspendForUser';
begin
  var H := FHLE;
  for var NID in [Cardinal($79D1C3FA), $B435DEC5, $920F104A, $C2DF770E, $80001C4C, $16641D70, $4FD31C9D, $FB05FAD0] do
    H.Register(U, NID, Format('sceKernelCache_%.8X', [NID]), hDcacheNop);
  H.Register(U, $3EE30821, 'sceKernelDcacheWritebackRange', hDcacheWritebackRange);
  H.Register(U, $34B9FA9E, 'sceKernelDcacheWritebackInvalidateRange', hDcacheWritebackRange);
  H.Register(U, $BFA98062, 'sceKernelDcacheInvalidateRange', hDcacheInvalidateRange);
  H.Register(U, $27CC57F0, 'sceKernelLibcTime', hLibcTime);
  H.Register(U, $71EC4271, 'sceKernelLibcGettimeofday', hLibcGettimeofday);
  H.Register(U, $91E4F6A7, 'sceKernelLibcClock', hLibcClock);
  H.Register(U, $C8186A58, 'sceKernelUtilsMd5Digest', hMd5Digest);
  H.Register(U, $9E5C5086, 'sceKernelUtilsMd5BlockInit', hMd5BlockInit);
  H.Register(U, $61E1E525, 'sceKernelUtilsMd5BlockUpdate', hMd5BlockUpdate);
  H.Register(U, $B8D24E78, 'sceKernelUtilsMd5BlockResult', hMd5BlockResult);
  H.Register(U, $840259F1, 'sceKernelUtilsSha1Digest', hSha1Digest);
  H.Register(U, $F8FCD5BA, 'sceKernelUtilsSha1BlockInit', hSha1BlockInit);
  H.Register(U, $346F6DA8, 'sceKernelUtilsSha1BlockUpdate', hSha1BlockUpdate);
  H.Register(U, $585F1C09, 'sceKernelUtilsSha1BlockResult', hSha1BlockResult);
  H.Register(U, $E860E75E, 'sceKernelUtilsMt19937Init', hMt19937Init);
  H.Register(U, $06FB8A63, 'sceKernelUtilsMt19937UInt', hMt19937UInt);
  H.Register(U, $37FB5C42, 'sceKernelGetGPI', hGetGPI);
  H.Register('Kernel_Library', $A089ECA4, 'sceKernelMemset', hKernelMemset);
  H.Register('Kernel_Library', $1839852A, 'sceKernelMemcpy', hKernelMemcpy);
  H.Register(U, $6AD345D7, 'sceKernelSetGPO', hZero);

  H.Register(P, $FDB5BFE9, 'scePowerGetCpuClockFrequencyInt', hPowerGetCpu);
  H.Register(P, $FEE03A2F, 'scePowerGetCpuClockFrequency', hPowerGetCpu);
  H.Register(P, $BD681969, 'scePowerGetBusClockFrequencyInt', hPowerGetBus);
  H.Register(P, $478FE6F5, 'scePowerGetBusClockFrequency', hPowerGetBus);
  H.Register(P, $34F9C463, 'scePowerGetPllClockFrequencyInt', hPowerGetPll);
  H.Register(P, $B1A52C83, 'scePowerGetCpuClockFrequencyFloat', hPowerGetCpuFloat);
  H.Register(P, $9BADB3EB, 'scePowerGetBusClockFrequencyFloat', hPowerGetBusFloat);
  H.Register(P, $EA382A27, 'scePowerGetPllClockFrequencyFloat', hPowerGetPllFloat);
  H.Register(P, $737486F2, 'scePowerSetClockFrequency', hPowerSetClock);
  H.Register(P, $545A7F3C, 'scePowerSetClockFrequency2', hPowerSetClock);
  H.Register(P, $EBD177D6, 'scePowerSetClockFrequency3', hPowerSetClock);
  H.Register(P, $469989AD, 'scePower_469989AD', hPowerSetClock);
  H.Register(P, $843FBF43, 'scePowerSetCpuClockFrequency', hPowerSetCpu);
  H.Register(P, $B8D7B3FB, 'scePowerSetBusClockFrequency', hPowerSetBus);
  H.Register(P, $04B7766E, 'scePowerRegisterCallback', hPowerRegisterCallback);
  H.Register(P, $DFA8BAF8, 'scePowerUnregisterCallback', hPowerUnregisterCallback);
  H.Register(P, $DB9D28DD, 'scePowerUnregitserCallback', hPowerUnregisterCallback);
  H.Register(P, $2085D15D, 'scePowerGetBatteryLifePercent', hPowerBatteryPercent);
  H.Register(P, $87440F5E, 'scePowerIsPowerOnline', hPowerOne);
  H.Register(P, $0AFD0D8B, 'scePowerIsBatteryExist', hPowerOne);
  H.Register(P, $1E490401, 'scePowerIsBatteryCharging', hPowerZero);
  H.Register(P, $D3075926, 'scePowerIsLowBattery', hPowerZero);
  H.Register(P, $B4432BC8, 'scePowerGetBatteryChargingStatus', hPowerZero);
  H.Register(P, $8EFB3FA2, 'scePowerGetBatteryLifeTime', hPowerBatteryLifeTime);
  H.Register(P, $28E12023, 'scePowerGetBatteryTemp', hPowerBatteryTemp);
  H.Register(P, $483CE86B, 'scePowerGetBatteryVolt', hPowerBatteryVolt);
  H.Register(P, $EFD3C963, 'scePowerTick', hPowerZero);
  H.Register(P, $D6D016EF, 'scePowerLock', hPowerZero);
  H.Register(P, $CA3D34C1, 'scePowerUnlock', hPowerZero);
  H.Register(P, $7F30B3B1, 'scePowerIdleTimerEnable', hPowerZero);
  H.Register(P, $972CE941, 'scePowerIdleTimerDisable', hPowerZero);
  H.Register(P, $DB62C9CF, 'scePowerCancelRequest', hPowerZero);
  H.Register(P, $78A1A796, 'scePowerIsSuspendRequired', hPowerZero);
  H.Register(P, $7FA406DD, 'scePowerIsRequest', hPowerZero);
  H.Register(P, $2B7C7CF4, 'scePowerRequestStandby', hPowerZero);
  H.Register(P, $AC32C9CC, 'scePowerRequestSuspend', hPowerZero);
  H.Register(P, $2875994B, 'scePowerRequestSuspendTouchAndGo', hPowerZero);
  H.Register(P, $0442D852, 'scePowerRequestColdReset', hPowerZero);
  H.Register(P, $94F5A53F, 'scePowerGetBatteryRemainCapacity', hPowerBatteryLifeTime);
  H.Register(P, $FD18A0FF, 'scePowerGetBatteryFullCapacity', hPowerBatteryLifeTime);
  H.Register(P, $862AE1A6, 'scePowerGetBatteryElec', hPowerZero);
  H.Register(P, $23436A4A, 'scePowerGetInnerTemp', hPowerBatteryTemp);
  H.Register(P, $0CD21B1F, 'scePowerSetPowerSwMode', hPowerZero);
  H.Register(P, $165CE085, 'scePowerGetPowerSwMode', hPowerZero);
  H.Register(P, $27F3292C, 'scePowerBatteryUpdateInfo', hPowerZero);
  H.Register(P, $E8E4E204, 'scePowerGetForceSuspendCapacity', hPowerZero);
  H.Register(P, $B999184C, 'scePowerGetLowBatteryCapacity', hPowerZero);
  H.Register(P, $EDC13FE5, 'scePowerGetIdleTimer', hPowerZero);
  H.Register(P, $442BFBAC, 'scePowerGetBacklightMaximum', hPowerZero);
  H.Register(P, $2B51FE2F, 'scePowerGetWlanActivity', hPowerZero);
  H.Register(P, $0074EF9B, 'scePowerGetResumeCount', hPowerZero);
  H.Register(P, $3951AF53, 'scePowerEncodeUBattery', hPowerZero);
  H.Register(P, $23C31FFE, 'scePowerVolatileMemLock', hPowerVolatileLock);
  H.Register(P, $FA97A599, 'scePowerVolatileMemTryLock', hPowerVolatileTryLock);
  H.Register(P, $B3EDD801, 'scePowerVolatileMemUnlock', hPowerVolatileUnlock);
  H.Register(S, $3E0271D3, 'sceKernelVolatileMemLock', hVolatileMemLock);
  H.Register(S, $A14F40B2, 'sceKernelVolatileMemTryLock', hVolatileMemTryLock);
  H.Register(S, $A569E425, 'sceKernelVolatileMemUnlock', hVolatileMemUnlock);
  H.Register(S, $EADB1BD7, 'sceKernelPowerLock', hKernelPowerLock);
  H.Register(S, $3AEE7261, 'sceKernelPowerUnlock', hKernelPowerLock);
  H.Register(S, $090CCB3F, 'sceKernelPowerTick', hKernelPowerTick);

  H.Register(M, $C6183D47, 'sceUmdActivate', hUmdActivate);
  H.Register(M, $E83742BA, 'sceUmdDeactivate', hUmdDeactivate);
  H.Register(M, $6B4A146C, 'sceUmdGetDriveStat', hUmdGetDriveStat);
  H.Register(M, $46EBB729, 'sceUmdCheckMedium', hUmdCheckMedium);
  H.Register(M, $8EF08FCE, 'sceUmdWaitDriveStat', hUmdWaitDriveStat);
  H.Register(M, $56202973, 'sceUmdWaitDriveStatWithTimer', hUmdWaitDriveStatWithTimer);
  H.Register(M, $4A9E5E29, 'sceUmdWaitDriveStatCB', hUmdWaitDriveStatCB);
  H.Register(M, $6AF9B50A, 'sceUmdCancelWaitDriveStat', hUmdCancelWaitDriveStat);
  H.Register(M, $AEE7404D, 'sceUmdRegisterUMDCallBack', hUmdRegisterCallback);
  H.Register(M, $BD2BDE07, 'sceUmdUnRegisterUMDCallBack', hUmdUnregisterCallback);
  H.Register(M, $340B7686, 'sceUmdGetDiscInfo', hUmdGetDiscInfo);
  H.Register(M, $20628E6F, 'sceUmdGetErrorStat', hUmdZero);
  H.Register(M, $87533940, 'sceUmdReplaceProhibit', hUmdZero);
  H.Register(M, $CBE9F02A, 'sceUmdReplacePermit', hUmdZero);

  H.Register(R, $3F7AD767, 'sceRtcGetCurrentTick', hRtcGetCurrentTick);
  H.Register(R, $C41C2853, 'sceRtcGetTickResolution', hRtcGetTickResolution);
  H.Register(R, $4CFA57B0, 'sceRtcGetCurrentClock', hRtcGetCurrentClock);
  H.Register(R, $E7C27D1B, 'sceRtcGetCurrentClockLocalTime', hRtcGetCurrentClockLocalTime);
  H.Register(R, $6FF40ACC, 'sceRtcGetTick', hRtcGetTick);
  H.Register(R, $7ED29E40, 'sceRtcSetTick', hRtcSetTick);
  H.Register(R, $44F45E05, 'sceRtcTickAddTicks', hRtcTickAddTicks);
  H.Register(R, $26D25A5D, 'sceRtcTickAddMicroseconds', hRtcTickAddMicroseconds);
  H.Register(R, $F2A4AFE5, 'sceRtcTickAddSeconds', hRtcTickAddSeconds);
  H.Register(R, $E6605BCA, 'sceRtcTickAddMinutes', hRtcTickAddMinutes);
  H.Register(R, $26D7A24A, 'sceRtcTickAddHours', hRtcTickAddHours);
  H.Register(R, $E51B4B7A, 'sceRtcTickAddDays', hRtcTickAddDays);
  H.Register(R, $CF3A2CA8, 'sceRtcTickAddWeeks', hRtcTickAddWeeks);
  H.Register(R, $DBF74F1B, 'sceRtcTickAddMonths', hRtcTickAddMonths);
  H.Register(R, $42842C77, 'sceRtcTickAddYears', hRtcTickAddYears);
  H.Register(R, $9ED0AE87, 'sceRtcCompareTick', hRtcCompareTick);
  H.Register(R, $34885E0D, 'sceRtcConvertUtcToLocalTime', hRtcConvertUtcToLocal);
  H.Register(R, $779242A2, 'sceRtcConvertLocalTimeToUTC', hRtcConvertLocalToUtc);
  H.Register(R, $05EF322C, 'sceRtcGetDaysInMonth', hRtcGetDaysInMonth);
  H.Register(R, $57726BC1, 'sceRtcGetDayOfWeek', hRtcGetDayOfWeek);
  H.Register(R, $42307A17, 'sceRtcIsLeapYear', hRtcIsLeapYear);
  H.Register(R, $4B1B5E82, 'sceRtcCheckValid', hRtcCheckValid);
  H.Register(R, $27C4594C, 'sceRtcGetTime_t', hRtcGetTime_t);
  H.Register(R, $3A807CC8, 'sceRtcSetTime_t', hRtcSetTime_t);
  H.Register(R, $E1C93E47, 'sceRtcGetTime64_t', hRtcGetTime64_t);
  H.Register(R, $1909C99B, 'sceRtcSetTime64_t', hRtcSetTime64_t);
  H.Register(R, $36075567, 'sceRtcGetDosTime', hRtcGetDosTime);
  H.Register(R, $F006F264, 'sceRtcSetDosTime', hRtcSetDosTime);
  H.Register(R, $CF561893, 'sceRtcGetWin32FileTime', hRtcGetWin32FileTime);
  H.Register(R, $7ACE4C04, 'sceRtcSetWin32FileTime', hRtcSetWin32FileTime);
  H.Register(R, $011F03C1, 'sceRtcGetAccumulativeTime', hRtcGetAccumulativeTime);
  H.Register(R, $029CA3B3, 'sceRtcGetAccumlativeTime', hRtcGetAccumulativeTime);
  H.Register(R, $C663B3B9, 'sceRtcFormatRFC2822', hRtcFormatRFC2822);
  H.Register(R, $7DE6711B, 'sceRtcFormatRFC2822LocalTime', hRtcFormatRFC2822Local);
  H.Register(R, $0498FB3C, 'sceRtcFormatRFC3339', hRtcFormatRFC3339);
  H.Register(R, $27F98543, 'sceRtcFormatRFC3339LocalTime', hRtcFormatRFC3339Local);
  H.Register(R, $DFBC5F16, 'sceRtcParseDateTime', hRtcParseDateTime);
  H.Register(R, $28E1E988, 'sceRtcParseRFC3339', hRtcParseDateTime);
  H.Register(R, $62685E98, 'sceRtcGetLastAdjustedTime', hRtcGetLastTime);
  H.Register(R, $203CEB0D, 'sceRtcGetLastReincarnatedTime', hRtcGetLastTime);

  H.Register(I, $24FD7BCF, 'sceImposeGetLanguageMode', hImposeGetLanguageMode);
  H.Register(I, $36AA6E91, 'sceImposeSetLanguageMode', hImposeZero);
  H.Register(I, $8C943191, 'sceImposeGetBatteryIconStatus', hImposeGetBatteryIconStatus);
  H.Register(I, $381BD9E7, 'sceImposeHomeButton', hImposeZero);
  H.Register(I, $5595A71A, 'sceImposeSetHomePopup', hImposeZero);
  H.Register(I, $0F341BE4, 'sceImposeGetHomePopup', hImposeGetHomePopup);
  H.Register(I, $72189C48, 'sceImposeSetUMDPopup', hImposeZero);
  H.Register(I, $E0887BC8, 'sceImposeGetUMDPopup', hImposeGetHomePopup);
  H.Register(I, $8F6E3518, 'sceImposeGetBacklightOffTime', hImposeZero);
  H.Register(I, $967F6D4A, 'sceImposeSetBacklightOffTime', hImposeZero);

  H.Register('sceHprm', $1910B327, 'sceHprmPeekCurrentKey', hHprmZero);
  H.Register('sceHprm', $2BCEC83E, 'sceHprmPeekLatch', hHprmZero);
  H.Register('sceHprm', $40D2F9F0, 'sceHprmReadLatch', hHprmZero);
  H.Register('sceHprm', $208DB1BD, 'sceHprmIsRemoteExist', hZero);
  H.Register('sceHprm', $7E69EDA4, 'sceHprmIsHeadphoneExist', hZero);
  H.Register('sceHprm', $219C58F1, 'sceHprmIsMicrophoneExist', hZero);
  H.Register('sceHprm', $C7154136, 'sceHprmRegisterCallback', hZero);
  H.Register('sceHprm', $444ED0B7, 'sceHprmUnregisterCallback', hZero);
  H.Register('sceDmac', $617F3FE6, 'sceDmacMemcpy', hDmacMemcpy);
  H.Register('sceDmac', $D97F94D8, 'sceDmacTryMemcpy', hDmacTryMemcpy);
  H.Register('sceOpenPSID', $C69BEBCE, 'sceOpenPSIDGetOpenPSID', hGetPSID);
end;

initialization
  RegisterPSPService(TPSPSysLibs);

end.

