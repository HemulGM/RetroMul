program PS2SystemTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Hash, System.IOUtils, Core.Snapshots,
  PS2.Types, PS2.Console, PS2.IOP.CDVD, PS2.IOP.MemoryCard, PS2.IOP.Kernel, PS2.IOP.Libs;

const
  // The recorded TPS2Console.SerializeState field sizes for this version.
  // A layout change must increase PS2SnapshotVersion and record a new pair.
  RecordedVersion = 3;
  RecordedFields = 657;
  RecordedLayout = '7a7c36a48246fb54900fa7717922569e900ea52eebed02717fc30a068b58a4c9';

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create(Message);
end;

function Seconds(Days, Hours, Minutes, Secs: Int64): Int64;
begin
  Result := ((Days * 24 + Hours) * 60 + Minutes) * 60 + Secs;
end;

procedure CheckClock;
type
  TCase = record
    Secs: Int64;
    Year, Month, Day, Hour, Minute, Second: Word;
  end;
const
  Cases: array[0..7] of TCase = (
    (Secs: 0; Year: 2004; Month: 1; Day: 1; Hour: 12; Minute: 0; Second: 0),
    (Secs: 59; Year: 2004; Month: 1; Day: 1; Hour: 12; Minute: 0; Second: 59),
    (Secs: 12 * 3600; Year: 2004; Month: 1; Day: 2; Hour: 0; Minute: 0; Second: 0),
    (Secs: 30 * 86400 + 11 * 3600 + 3599; Year: 2004; Month: 1; Day: 31; Hour: 23; Minute: 59; Second: 59),
    (Secs: 31 * 86400; Year: 2004; Month: 2; Day: 1; Hour: 12; Minute: 0; Second: 0),
    (Secs: 59 * 86400; Year: 2004; Month: 2; Day: 29; Hour: 12; Minute: 0; Second: 0),
    (Secs: 366 * 86400; Year: 2005; Month: 1; Day: 1; Hour: 12; Minute: 0; Second: 0),
    (Secs: 3652 * 86400; Year: 2013; Month: 12; Day: 31; Hour: 12; Minute: 0; Second: 0));
begin
  for var C in Cases do
    for var Fraction in TArray<Int64>.Create(0, PS2EEClock - 1) do
    begin
      var T := PS2ClockAt(C.Secs * PS2EEClock + Fraction);
      Check((T.Year = C.Year) and (T.Month = C.Month) and (T.Day = C.Day) and (T.Hour = C.Hour) and
        (T.Minute = C.Minute) and (T.Second = C.Second), Format('Clock mismatch at %d seconds', [C.Secs]));
    end;
  // Every second for 400 days (a leap day and a year change) against an
  // independent integer calendar, at the start and end of the second.
  var Year := 2004; var Month := 1; var Day := 1;
  var Second: Int64 := 12 * 3600;
  for var S := 0 to 400 * 86400 do
  begin
    for var Fraction in TArray<Int64>.Create(0, 1, PS2EEClock - 1) do
    begin
      var T := PS2ClockAt(Int64(S) * PS2EEClock + Fraction);
      Check((T.Year = Year) and (T.Month = Month) and (T.Day = Day) and (T.Hour = Second div 3600) and
        (T.Minute = (Second div 60) mod 60) and (T.Second = Second mod 60),
        Format('Exact clock second mismatch at %d seconds', [S]));
    end;
    Inc(Second);
    if Second = 86400 then
    begin
      Second := 0;
      Inc(Day);
      var Days := 31;
      case Month of
        4, 6, 9, 11: Days := 30;
        2: if (Year mod 4 = 0) and ((Year mod 100 <> 0) or (Year mod 400 = 0)) then Days := 29 else Days := 28;
      end;
      if Day > Days then
      begin
        Day := 1;
        Inc(Month);
        if Month > 12 then begin Month := 1; Inc(Year); end;
      end;
    end;
  end;
  var Negative := PS2ClockAt(-PS2EEClock);
  Check((Negative.Year = 2004) and (Negative.Hour = 12) and (Negative.Second = 0), 'Negative clock was not clamped');
  for var V := 0 to 99 do
    Check(Integer(PS2BCD(V)) = ((V div 10) shl 4) or (V mod 10), 'BCD mismatch');

  var FS := TPS2DiscFileSystem.Create(nil, '', TPS2Region.Japan);
  var Server := TPS2CDVDServer.Create($80000593, FS);
  var Args: array[0..63] of Byte;
  var Cycles: Int64;
  try
    Server.Clock := @Cycles;
    for var C in Cases do
    begin
      Cycles := C.Secs * PS2EEClock;
      FillChar(Args, SizeOf(Args), 0);
      var R := Server.Call(1, @Args[0], SizeOf(Args), 32);
      var T := PS2ClockAt(Cycles);
      Check((R[5] = PS2BCD(T.Second)) and (R[6] = PS2BCD(T.Minute)) and (R[7] = PS2BCD(T.Hour)) and
        (R[9] = PS2BCD(T.Day)) and (R[10] = PS2BCD(T.Month)) and (R[11] = PS2BCD(T.Year mod 100)),
        Format('CDVD RPC clock mismatch at %d seconds', [C.Secs]));
      var Card := PS2CardTime(Cycles);
      Check(Card = (UInt64(T.Second) shl 8) or (UInt64(T.Minute) shl 16) or (UInt64(T.Hour) shl 24) or
        (UInt64(T.Day) shl 32) or (UInt64(T.Month) shl 40) or (UInt64(T.Year) shl 48),
        Format('Memory card clock mismatch at %d seconds', [C.Secs]));
    end;
  finally
    Server.Free;
    FS.Free;
  end;

  // The IOP library call reads the console scheduler, never host time.
  var Console := TPS2Console.Create(Default(TPS2ConsoleConfig));
  try
    for var C in Cases do
    begin
      Console.Scheduler.Now := C.Secs * PS2EEClock + 12345;
      const Address: Cardinal = $1000;
      for var K := 0 to 7 do
        Console.IOP.W8(Address + Cardinal(K), $EE);
      Console.IOP.CPU.R[4] := Address;
      IOPLibraryCall(Console.IOP, 16, 24);
      var T := PS2ClockAt(Console.Scheduler.Now);
      Check((Console.IOP.R8(Address) = 0) and (Console.IOP.R8(Address + 1) = PS2BCD(T.Second)) and
        (Console.IOP.R8(Address + 2) = PS2BCD(T.Minute)) and (Console.IOP.R8(Address + 3) = PS2BCD(T.Hour)) and
        (Console.IOP.R8(Address + 4) = 0) and (Console.IOP.R8(Address + 5) = PS2BCD(T.Day)) and
        (Console.IOP.R8(Address + 6) = PS2BCD(T.Month)) and
        (Console.IOP.R8(Address + 7) = PS2BCD(T.Year mod 100)),
        Format('IOP sceCdReadClock mismatch at %d seconds', [C.Secs]));
    end;
  finally
    Console.Free;
  end;
  Writeln('Console clock: calendar/leap/BCD, CDVD RPC, IOP cdvdman and memory cards use emulated time: OK');
end;

function StateBytes(Console: TPS2Console): TBytes;
begin
  var S := TMemoryStream.Create;
  try
    var A := TStateArchive.Create(S, False);
    try Console.SerializeState(A); finally A.Free; end;
    SetLength(Result, S.Size);
    if S.Size > 0 then
      Move(S.Memory^, Result[0], S.Size);
  finally
    S.Free;
  end;
end;

procedure LoadBytes(Console: TPS2Console; const Bytes: TBytes);
begin
  var S := TBytesStream.Create(Bytes);
  try
    var A := TStateArchive.Create(S, True);
    try Console.SerializeState(A); finally A.Free; end;
    Check(S.Position = S.Size, 'Snapshot payload was not consumed exactly');
  finally
    S.Free;
  end;
end;

procedure Layout(const Bytes: TBytes; out Fields: Integer; out Digest: string);
begin
  var Sizes := TMemoryStream.Create;
  try
    var P := 0;
    Fields := 0;
    while P < Length(Bytes) do
    begin
      Check(P + 4 <= Length(Bytes), 'Truncated snapshot field header');
      var Size := PInteger(@Bytes[P])^;
      Check((Size >= 0) and (P + 4 + Size <= Length(Bytes)), 'Invalid snapshot field size');
      Sizes.WriteBuffer(Size, SizeOf(Size));
      Inc(P, 4 + Size);
      Inc(Fields);
    end;
    Sizes.Position := 0;
    Digest := THashSHA2.GetHashString(Sizes);
  finally
    Sizes.Free;
  end;
end;

procedure CheckSnapshots;
begin
  var Config := Default(TPS2ConsoleConfig);
  var A := TPS2Console.Create(Config);
  var B := TPS2Console.Create(Config);
  try
    A.Scheduler.Now := 123456789;
    var Saved := StateBytes(A);
    LoadBytes(B, Saved);
    var Restored := StateBytes(B);
    Check((Length(Saved) = Length(Restored)) and CompareMem(@Saved[0], @Restored[0], Length(Saved)),
      'Fresh console snapshot did not round-trip');
    var Fields: Integer;
    var Digest: string;
    Layout(Saved, Fields, Digest);
    Writeln(Format('snapshot layout: version %d, %d fields, %s', [PS2SnapshotVersion, Fields, Digest]));
    if (PS2SnapshotVersion <> RecordedVersion) or (Fields <> RecordedFields) or (Digest <> RecordedLayout) then
      raise Exception.CreateFmt('Snapshot layout/version pair changed: recorded %d/%d/%s, actual %d/%d/%s. ' +
        'Increase PS2SnapshotVersion for a layout change and record the new pair.',
        [RecordedVersion, RecordedFields, RecordedLayout, PS2SnapshotVersion, Fields, Digest]);

    RegisterSnapshotPolicy('PS2', TPS2Console.SnapshotPolicy);
    var Dir := TPath.Combine(TPath.GetTempPath, 'ps2-system-test-' + TGUID.NewGuid.ToString);
    ForceDirectories(Dir);
    var Path := TPath.Combine(Dir, 'state.rmsnap');
    var ROM := TBytes.Create(1, 2, 3, 4);
    var Transfer: TStateTransfer := procedure(State: TStateArchive) begin A.SerializeState(State); end;
    SaveCoreSnapshot(Path, 'PS2', ROM, Transfer);
    var Target: TStateTransfer := procedure(State: TStateArchive) begin B.SerializeState(State); end;
    B.Scheduler.Now := 7;
    LoadCoreSnapshot(Path, 'PS2', ROM, Target);
    Check(B.Scheduler.Now = 123456789, 'Header snapshot did not load');

    var Original := TFile.ReadAllBytes(Path);
    var Old := Copy(Original);
    PCardinal(@Old[8])^ := 1; // header version of a build before format 3
    var OldPath := TPath.Combine(Dir, 'old.rmsnap');
    TFile.WriteAllBytes(OldPath, Old);
    B.Scheduler.Now := 7;
    var Message := '';
    try
      LoadCoreSnapshot(OldPath, 'PS2', ROM, Target);
    except
      on E: EReadError do Message := E.Message;
    end;
    Check(Message = Format(TPS2Console.SnapshotPolicy.VersionError, [1, PS2SnapshotVersion]),
      'Old snapshot did not report its format: ' + Message);
    Check(B.Scheduler.Now = 7, 'Rejected snapshot changed console state');

    Message := '';
    try
      LoadCoreSnapshot(Path, 'PS2', TBytes.Create(9), Target);
    except
      on E: EReadError do Message := E.Message;
    end;
    Check(Message = TPS2Console.SnapshotPolicy.IdentityError, 'Wrong disc did not report identity: ' + Message);
    TDirectory.Delete(Dir, True);
  finally
    B.Free;
    A.Free;
  end;
  Writeln('Snapshots: exact round-trip, recorded layout, old-format and wrong-disc messages, rejected loads keep state: OK');
end;

begin
  try
    CheckClock;
    CheckSnapshots;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
