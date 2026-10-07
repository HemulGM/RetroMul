unit MSX.AudioMachine;

interface

uses
  System.SysUtils, MD.Z80, SMS.Sound.SN76489, ZX.Sound.YM2149, MSX.Sound.SCC,
  MSX.Sound.OPLL, PC.Sound.OPL, Core.AudioFilter;

type
  TKSSAudio = class
  private
    FData: TBytes;
    FMemory: array[0..65535] of Byte;
    FCPU: TZ80State;
    FBus: TZ80ReadAndWriteCallbacks;
    FAY: TYM2149F;
    FSCC: TSCC;
    FOPLL: TYM2413;
    FAudio: TOPL1;
    FSN: TSN76489;
    FFlags, FDataStart, FLoadAddress, FLoadSize, FInit, FPlay, FFirstBank, FBankCount, FBankSize, FRate: Integer;
    FBanks: array[0..1] of Integer;
    FGG: Byte;
    FDebt, FTimer: Double;
    FDC: array[0..1] of TPCMDCBlocker;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    function InPort(Address: Cardinal): Cardinal;
    procedure OutPort(Address, Value: Cardinal);
    procedure Call(Address: Integer);
    function WordAt(P: Integer): Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset(Track: Integer);
    procedure Sample(out Left, Right: SmallInt);
    function FirstTrack: Integer;
    function LastTrack: Integer;
  end;

implementation

uses
  System.Math;

function MemRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TKSSAudio(Context).Read(Address);
end;

procedure MemWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TKSSAudio(Context).Write(Address, Value);
end;

function PortRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TKSSAudio(Context).InPort(Address);
end;

procedure PortWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TKSSAudio(Context).OutPort(Address, Value);
end;

function TKSSAudio.WordAt(P: Integer): Integer;
begin
  if (P < 0) or (P > Length(FData) - 2) then
    raise EArgumentException.Create('KSS header');
  Result := Integer(FData[P]) + Integer(FData[P + 1]) * 256;
end;

constructor TKSSAudio.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Copy(Data);
  if (Length(Data) < 16) or not ((TEncoding.ASCII.GetString(Data, 0, 4) = 'KSCC') or (TEncoding.ASCII.GetString(Data, 0, 4) = 'KSSX')) then
    raise EArgumentException.Create('Invalid KSS signature');
  FDataStart := 16;
  if Data[3] = Ord('X') then
  begin
    if not (Data[14] in [0, 16]) then
      raise EArgumentException.Create('KSSX extended header');
    Inc(FDataStart, Data[14]);
  end;
  FLoadAddress := WordAt(4);
  FLoadSize := WordAt(6);
  FInit := WordAt(8);
  FPlay := WordAt(10);
  FFirstBank := Data[12];
  FBankCount := Data[13] and 127;
  FBankSize := 16384 shr (Data[13] shr 7);
  FFlags := Data[15];
  FRate := 60;
  if FFlags and $40 <> 0 then
    FRate := 50;
  if (FDataStart > Length(Data)) or (FLoadSize > Length(Data) - FDataStart) or (FLoadSize > 65536 - FLoadAddress) or (FBankCount * FBankSize > Length(Data) - FDataStart - FLoadSize) then
    raise EArgumentException.Create('Truncated KSS memory/banks');
  if (FDataStart = 32) and (LastTrack < FirstTrack) then
    raise EArgumentException.Create('Invalid KSSX track range');
  FAY := TYM2149F.Create(1789772);
  FAY.AYModel := True;
  for var I := 0 to 2 do
    FAY.SetPan(I, 1, 1);
  FSCC := TSCC.Create;
  FOPLL := TYM2413.Create;
  FAudio := TOPL1.Create;
  FSN := TSN76489.Create;
  FBus := Default(TZ80ReadAndWriteCallbacks);
  FBus.UserData := Self;
  FBus.ReadCallback := MemRead;
  FBus.WriteCallback := MemWrite;
  FBus.PortReadCallback := PortRead;
  FBus.PortWriteCallback := PortWrite;
  for var I := 0 to 1 do
    FDC[I].Configure(44100, 20);
  Reset(FirstTrack);
end;

destructor TKSSAudio.Destroy;
begin
  FAY.Free;
  FSCC.Free;
  FOPLL.Free;
  FAudio.Free;
  FSN.Free;
  inherited;
end;

function TKSSAudio.FirstTrack: Integer;
begin
  Result := 0;
  if FDataStart = 32 then
    Result := WordAt(24);
end;

function TKSSAudio.LastTrack: Integer;
begin
  Result := 255;
  if FDataStart = 32 then
    Result := WordAt(26);
  if Result > 255 then
    raise EArgumentException.Create('KSS track range exceeds Z80 register');
end;

procedure TKSSAudio.Call(Address: Integer);
begin
  FCPU.StackPointer := (Integer(FCPU.StackPointer) - 1) and $FFFF;
  FMemory[FCPU.StackPointer] := $FF;
  FCPU.StackPointer := (Integer(FCPU.StackPointer) - 1) and $FFFF;
  FMemory[FCPU.StackPointer] := $FF;
  FCPU.ProgramCounter := Address;
  FCPU.Halted := False;
end;

procedure TKSSAudio.Reset(Track: Integer);
const
  BIOS: array[0..12] of Byte = ($D3, $A0, $F5, $7B, $D3, $A1, $F1, $C9, $D3, $A0, $DB, $A2, $C9);
begin
  if (Track < FirstTrack) or (Track > LastTrack) then
    raise EArgumentOutOfRangeException.Create('KSS track');
  for var I := 0 to $3FFF do
    FMemory[I] := $C9;
  for var I := $4000 to $FFFF do
    FMemory[I] := 0;
  for var I := 0 to High(BIOS) do
    FMemory[1 + I] := BIOS[I];
  FMemory[$93] := $C3;
  FMemory[$94] := 1;
  FMemory[$95] := 0;
  FMemory[$96] := $C3;
  FMemory[$97] := 9;
  FMemory[$98] := 0;
  for var I := 0 to FLoadSize - 1 do
    FMemory[FLoadAddress + I] := FData[FDataStart + I];
  FCPU := Default(TZ80State);
  Z80Reset(FCPU);
  FCPU.A := Track;
  FCPU.StackPointer := $F380;
  FBanks[0] := -1;
  FBanks[1] := -1;
  FAY.Reset;
  FSCC.Reset;
  FOPLL.Reset;
  FAudio.Reset;
  FSN.Reset;
  FGG := $FF;
  FDebt := 0;
  FTimer := 0;
  for var I := 0 to 1 do
    FDC[I].Reset;
  Call(FInit);
end;

function TKSSAudio.Read(Address: Cardinal): Cardinal;
begin
  var A := Integer(Address and $FFFF);
  if (A >= $8000) and (A < $C000) then
  begin
    var Logical := 0;
    if FBankSize = 8192 then
      Logical := (A - $8000) div 8192;
    var Physical := FBanks[Logical] - FFirstBank;
    if (Physical >= 0) and (Physical < FBankCount) then
      Exit(FData[FDataStart + FLoadSize + Physical * FBankSize + (A - $8000) mod FBankSize]);
  end;
  Result := FMemory[A];
end;

procedure TKSSAudio.Write(Address, Value: Cardinal);
begin
  var A := Integer(Address and $FFFF);
  var V := Byte(Value and 255);
  FMemory[A] := V;
  if A = $9000 then
    FBanks[0] := V
  else if A = $B000 then
    FBanks[1] := V
  else if (FFlags and $86 = 0) then
  begin
    if (A >= $9800) and (A < $9900) then
      FSCC.WriteRegister(A - $9800, V, False)
    else if (A >= $B800) and (A < $B900) then
      FSCC.WriteRegister(A - $B800, V, True);
  end;
end;

function TKSSAudio.InPort(Address: Cardinal): Cardinal;
begin
  case Address and 255 of
    $A2:
      Result := FAY.ReadData;
    $C0, $C1:
      Result := FAudio.ReadPort(Address and 1);
    $A8:
      Result := 0;
  else
    Result := $FF;
  end;
end;

procedure TKSSAudio.OutPort(Address, Value: Cardinal);
begin
  var P := Address and 255;
  var V := Byte(Value and 255);
  case P of
    $A0:
      FAY.WriteAddress(V);
    $A1:
      FAY.WriteData(V);
    $FE:
      FBanks[0] := V;
    $7C, $7D:
      if FFlags and 3 = 1 then
        FOPLL.WritePort(P and 1, V);
    $F0, $F1:
      if FFlags and 3 = 3 then
        FOPLL.WritePort(P and 1, V);
    $C0, $C1:
      if FFlags and 10 = 8 then
        FAudio.WritePort(P and 1, V);
    $7E, $7F:
      if FFlags and 2 <> 0 then
        FSN.Write(V);
    6:
      if FFlags and 6 = 6 then
        FGG := V;
  end;
end;

procedure TKSSAudio.Sample(out Left, Right: SmallInt);
begin
  FDebt := FDebt + 3579545.0 / 44100;
  FTimer := FTimer + FRate / 44100.0;
  if FTimer >= 1 then
  begin
    FTimer := FTimer - 1;
    if FCPU.ProgramCounter = $FFFF then
      Call(FPlay);
  end;
  while FDebt > 0 do
  begin
    if FCPU.ProgramCounter = $FFFF then
    begin
      FDebt := 0;
      Break;
    end;
    var Cycles := Z80DoInstruction(FCPU, FBus);
    if Cycles = 0 then
      Cycles := 4;
    FDebt := FDebt - Cycles;
  end;
  var L, R: SmallInt;
  var SumL, SumR: Integer;
  if FFlags and 2 = 0 then
  begin
    FAY.Sample(L, R);
    SumL := L;
    SumR := R;
    var S := 0;
    if FFlags and $80 = 0 then
      S := FSCC.Sample;
    Inc(SumL, S);
    Inc(SumR, S);
  end
  else
  begin
    FSN.Sample(FGG, L, R);
    SumL := L;
    SumR := R;
  end;
  if FFlags and 1 <> 0 then
  begin
    FOPLL.Sample(L, R);
    Inc(SumL, L);
    Inc(SumR, R);
  end;
  if (FFlags and 10 = 8) then
  begin
    FAudio.Sample(L, R);
    Inc(SumL, L);
    Inc(SumR, R);
  end;
  Left := EnsureRange(Round(FDC[0].Process(SumL)), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(SumR)), -32768, 32767);
end;

initialization
  ConstantInitialise;

end.

