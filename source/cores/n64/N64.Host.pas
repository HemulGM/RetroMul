unit N64.Host;

// The host's processor cores, for placing the core's threads: which logical
// processors share a core (SMT siblings), how fast each core is (Windows
// efficiency classes, Linux/Android maximum frequencies: big.LITTLE), and
// pinning the calling thread to a set of logical processors. Where any of
// this is unavailable, nothing is placed; the emulation does not depend on it.

interface

type
  // Logical processors 0..1023.
  TN64CPUSet = record
    Bits: array[0..15] of UInt64;
    procedure Clear;
    procedure Include(CPU: Integer);
    function Contains(CPU: Integer): Boolean;
    function IsEmpty: Boolean;
    function Count: Integer;
  end;

  // A physical core: its logical processors this process may use, and its
  // speed (larger is faster; only the order matters).
  TN64HostCore = record
    CPUs: TN64CPUSet;
    Speed: Int64;
  end;

// The cores this process may use, fastest first; among equally fast cores,
// the one the calling thread runs on first, then by processor number.
function HostCores: TArray<TN64HostCore>;
// The logical processor the calling thread runs on (-1 if unknown).

function CurrentProcessor: Integer;
// Pins the calling thread to CPUs; Previous receives what it may run on
// before. False (nothing changed) where unsupported.

function PinCurrentThread(const CPUs: TN64CPUSet; out Previous: TN64CPUSet): Boolean;
// Asks the scheduler to prefer logical processor CPU for the calling thread
// (a hint, Windows only).

procedure PreferProcessor(CPU: Integer);
// Same hint, returning the previous preference for an owning thread to restore.

function SuggestProcessor(CPU: Integer): Integer;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  {$IF DEFINED(LINUX) or DEFINED(ANDROID)}
  Posix.Base, System.Classes,
  {$ENDIF}
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults;

{$IF DEFINED(LINUX) or DEFINED(ANDROID)}
function sched_setaffinity(pid: Int32; cpusetsize: NativeUInt; mask: Pointer): Int32; cdecl; external libc name 'sched_setaffinity';

function sched_getaffinity(pid: Int32; cpusetsize: NativeUInt; mask: Pointer): Int32; cdecl; external libc name 'sched_getaffinity';

function sched_getcpu: Int32; cdecl; external libc name 'sched_getcpu';
{$ENDIF}

{ TN64CPUSet }

procedure TN64CPUSet.Clear;
begin
  for var I := 0 to High(Bits) do
    Bits[I] := 0;
end;

procedure TN64CPUSet.Include(CPU: Integer);
begin
  if (CPU >= 0) and (CPU < 1024) then
    Bits[CPU shr 6] := Bits[CPU shr 6] or (UInt64(1) shl (CPU and 63));
end;

function TN64CPUSet.Contains(CPU: Integer): Boolean;
begin
  Result := (CPU >= 0) and (CPU < 1024) and ((Bits[CPU shr 6] and (UInt64(1) shl (CPU and 63))) <> 0);
end;

function TN64CPUSet.IsEmpty: Boolean;
begin
  for var I := 0 to High(Bits) do
    if Bits[I] <> 0 then
      Exit(False);
  Result := True;
end;

function TN64CPUSet.Count: Integer;
begin
  Result := 0;
  for var I := 0 to 1023 do
    if Contains(I) then
      Inc(Result);
end;

function CurrentProcessor: Integer;
begin
  {$IF DEFINED(MSWINDOWS)}
  Result := Integer(GetCurrentProcessorNumber);
  {$ELSEIF DEFINED(LINUX) or DEFINED(ANDROID)}
  Result := sched_getcpu;
  {$ELSE}
  Result := -1;
  {$ENDIF}
end;

function SuggestProcessor(CPU: Integer): Integer;
begin
  Result := -1;
  {$IFDEF MSWINDOWS}
  // 64 removes an existing group-0 preference (MAXIMUM_PROCESSORS).
  if (CPU >= 0) and (CPU <= 64) then
    Result := Integer(SetThreadIdealProcessor(GetCurrentThread, DWORD(CPU)));
  {$ENDIF}
end;

procedure PreferProcessor(CPU: Integer);
begin
  SuggestProcessor(CPU);
end;

procedure SortCores(var Cores: TArray<TN64HostCore>);
begin
  var Here := CurrentProcessor;
  TArray.Sort<TN64HostCore>(Cores, TComparer<TN64HostCore>.Construct(
    function(const A, B: TN64HostCore): Integer
    begin
      if A.Speed <> B.Speed then
        Exit(Ord((A.Speed) < (B.Speed)) - Ord(A.Speed > B.Speed));

      if A.CPUs.Contains(Here) <> B.CPUs.Contains(Here) then
        Exit(Ord(B.CPUs.Contains(Here)) - Ord(A.CPUs.Contains(Here)));
      // By the first processor of each.
      var FA := 0;
      while (FA < 1024) and not A.CPUs.Contains(FA) do
        Inc(FA);
      var FB := 0;
      while (FB < 1024) and not B.CPUs.Contains(FB) do
        Inc(FB);
      Result := FA - FB;
    end));
end;

{$IFDEF MSWINDOWS}
function HostCores: TArray<TN64HostCore>;
begin
  // Processor group 0 only (up to 64 logical processors).
  Result := nil;
  var ProcessMask, SystemMask: DWORD_PTR;
  if not GetProcessAffinityMask(GetCurrentProcess, ProcessMask, SystemMask) then
    Exit;
  var Length_: DWORD := 0;
  GetLogicalProcessorInformationEx(RelationProcessorCore, nil, @Length_);
  if Length_ = 0 then
    Exit;
  var Buffer: TBytes;
  SetLength(Buffer, Length_);
  // (Declared with the non-Ex record type; the layout is the Ex one.)
  if not GetLogicalProcessorInformationEx(RelationProcessorCore, PSystemLogicalProcessorInformation(@Buffer[0]), @Length_) then
    Exit;
  var List := TList<TN64HostCore>.Create;
  try
    var Offset: DWORD := 0;
    while Offset < Length_ do
    begin
      var Info := PSystemLogicalProcessorInformationEx(@Buffer[Offset]);
      if Info.Size = 0 then
        Break;
      if (Info.Relationship = RelationProcessorCore) and (Info.Processor.GroupCount >= 1) and
        (Info.Processor.GroupMask[0].Group = 0) then
      begin
        var Mask := UInt64(Info.Processor.GroupMask[0].Mask) and UInt64(ProcessMask);
        if Mask <> 0 then
        begin
          var Core := Default(TN64HostCore);
          Core.CPUs.Bits[0] := Mask;
          // EfficiencyClass follows Flags (higher is faster).
          Core.Speed := Info.Processor.Reserved[0];
          List.Add(Core);
        end;
      end;
      Inc(Offset, Info.Size);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
  SortCores(Result);
end;

function PinCurrentThread(const CPUs: TN64CPUSet; out Previous: TN64CPUSet): Boolean;
begin
  Previous.Clear;
  var Mask := DWORD_PTR(CPUs.Bits[0]);
  if Mask = 0 then
    Exit(False);
  var Old := SetThreadAffinityMask(GetCurrentThread, Mask);
  Result := Old <> 0;
  if Result then
    Previous.Bits[0] := UInt64(Old);
end;
{$ENDIF}

{$IF DEFINED(LINUX) or DEFINED(ANDROID)}

function ReadNumber(const Path: string; Default: Int64): Int64;
begin
  // The first decimal number in a /sys file. (Such a file claims a page's
  // size and holds a few bytes: TFile.ReadAllText, which reads the size,
  // fails on it; this reads what there is.)
  Result := Default;
  try
    var Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      var Text: array[0..63] of Byte;
      var Count := Stream.Read(Text, SizeOf(Text));
      var Value: Int64 := 0;
      var Digits := 0;
      while (Digits < Count) and (Text[Digits] >= Ord('0')) and (Text[Digits] <= Ord('9')) do
      begin
        Value := Value * 10 + (Text[Digits] - Ord('0'));
        Inc(Digits);
      end;
      if Digits > 0 then
        Result := Value;
    finally
      Stream.Free;
    end;
  except
    Result := Default;
  end;
end;

function HostCores: TArray<TN64HostCore>;
begin
  Result := nil;
  var Allowed: TN64CPUSet;
  Allowed.Clear;
  if sched_getaffinity(0, SizeOf(Allowed.Bits), @Allowed.Bits[0]) <> 0 then
    Exit;
  var List := TList<TN64HostCore>.Create;
  try
    // A core is keyed by the first processor of its SMT siblings.
    var Keys: TArray<Integer>;
    for var CPU := 0 to 1023 do
    begin
      if not Allowed.Contains(CPU) then
        Continue;
      var Base := '/sys/devices/system/cpu/cpu' + IntToStr(CPU);
      var Key := Integer(ReadNumber(Base + '/topology/thread_siblings_list', CPU));
      var Speed := ReadNumber(Base + '/cpufreq/cpuinfo_max_freq', 0);
      var Found := -1;
      for var K := 0 to High(Keys) do
        if Keys[K] = Key then
          Found := K;
      if Found < 0 then
      begin
        var Core := Default(TN64HostCore);
        Core.Speed := Speed;
        List.Add(Core);
        Keys := Keys + [Key];
        Found := List.Count - 1;
      end;
      var Core := List[Found];
      Core.CPUs.Include(CPU);
      if Speed > Core.Speed then
        Core.Speed := Speed;
      List[Found] := Core;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
  SortCores(Result);
end;

function PinCurrentThread(const CPUs: TN64CPUSet; out Previous: TN64CPUSet): Boolean;
begin
  Previous.Clear;
  if CPUs.IsEmpty then
    Exit(False);
  if sched_getaffinity(0, SizeOf(Previous.Bits), @Previous.Bits[0]) <> 0 then
    Exit(False);
  Result := sched_setaffinity(0, SizeOf(CPUs.Bits), @CPUs.Bits[0]) = 0;
end;
{$ENDIF}

{$IF not DEFINED(MSWINDOWS) and not DEFINED(LINUX) and not DEFINED(ANDROID)}

function HostCores: TArray<TN64HostCore>;
begin
  Result := nil;
end;

function PinCurrentThread(const CPUs: TN64CPUSet; out Previous: TN64CPUSet): Boolean;
begin
  Previous.Clear;
  Result := False;
end;
{$ENDIF}

end.

