unit RetroTune.Decoder.GBS;

interface

uses
  System.SysUtils, RetroTune.Decoder, GB.CPU, GB.Memory, GB.Sound, GB.GPU,
  GB.Timer, GB.InterruptManager, GB.Joypad;

type
  TGBSMemory = class(TGBMemory)
  public
    ROM: TBytes;
    Bank: Integer;
    Fast: Boolean;
    function ReadByte(Address: Integer): Byte; override;
    procedure WriteByte(Address: Integer; Value: Byte); override;
  protected
    function GetDoubleSpeed: Boolean; override;
  end;

  TGBSDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData: TBytes;
    FMemory: TGBSMemory;
    FCPU: TGBCPU;
    FSound: TGBSound;
    FGPU: TGBGPU;
    FTimer: TGBTimer;
    FIRQ: TGBInterruptManager;
    FJoy: TGBJoypad;
    FPCM: TArray<SmallInt>;
    FRead: Integer;
    FNextPlay: UInt64;
    FReady: Boolean;
    procedure ReleaseMachine;
    procedure CallRoutine(Address: Word);
    procedure ReceivePCM(PCM: TArray<SmallInt>; Frames: Integer);
    function Period: Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

implementation

uses
  System.Math, RetroTune.Binary;

function TGBSMemory.GetDoubleSpeed: Boolean;
begin
  Result := Fast;
end;

function TGBSMemory.ReadByte(Address: Integer): Byte;
begin
  if Address < $8000 then
  begin
    var Offset := Address;
    if Address >= $4000 then
      Offset := Bank * $4000 + (Address and $3FFF);
    if (Offset >= 0) and (Offset < Length(ROM)) then
      Exit(ROM[Offset]);
    Exit(0);
  end;
  if (Address >= $A000) and (Address <= $BFFF) then
    Exit(ExtRAM[Address - $A000]);
  Result := inherited ReadByte(Address);
end;

procedure TGBSMemory.WriteByte(Address: Integer; Value: Byte);
begin
  if Address < $8000 then
  begin
    if (Address >= $2000) and (Address < $4000) then
      Bank := Value;
    Exit;
  end;
  if (Address >= $A000) and (Address <= $BFFF) then
  begin
    ExtRAM[Address - $A000] := Value;
    Exit;
  end;
  if Address = $FF70 then
    Exit;
  inherited WriteByte(Address, Value);
end;

constructor TGBSDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  RequireBytes(Data, 0, $71);
  if (TEncoding.ASCII.GetString(Data, 0, 3) <> 'GBS') or (Data[3] <> 1) then
    raise EArgumentException.Create('Invalid GBS signature or version');
  if (Data[4] = 0) or (Data[5] = 0) or (Data[5] > Data[4]) then
    raise EArgumentException.Create('Invalid GBS track count');
  for var Offset in [6, 8, 10] do
    if (LE16(Data, Offset) < $400) or (LE16(Data, Offset) > $7FFF) then
      raise EArgumentException.Create('Invalid GBS routine address');
  if (Data[$F] and $78) <> 0 then
    raise ENotSupportedException.Create('GBS custom interrupt table / reserved timer flags are unsupported');
  if Length(Data) - $70 + LE16(Data, 6) > $400000 then
    raise EArgumentException.Create('GBS data exceeds 256 ROM banks');
  FData := Copy(Data);
  FInfo.Title := TextField(Data, $10, 32);
  FInfo.Artist := TextField(Data, $30, 32);
  FInfo.CopyrightText := TextField(Data, $50, 32);
  FInfo.FormatName := 'GBS';
  FInfo.Details := 'Game Boy';
  if (Data[$F] and $80) <> 0 then
    FInfo.Details := 'Game Boy Color / double speed';
  FInfo.TrackCount := Data[4];
  FInfo.DefaultTrack := Data[5] - 1;
  FInfo.SampleRate := GB_AUDIO_SAMPLE_RATE;
  FInfo.Channels := 2;
end;

procedure TGBSDecoder.ReleaseMachine;
begin
  FreeAndNil(FCPU);
  FreeAndNil(FSound);
  FreeAndNil(FMemory);
  FreeAndNil(FGPU);
  FreeAndNil(FTimer);
  FreeAndNil(FJoy);
  FreeAndNil(FIRQ);
end;

destructor TGBSDecoder.Destroy;
begin
  ReleaseMachine;
  inherited;
end;

function TGBSDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TGBSDecoder.ReceivePCM(PCM: TArray<SmallInt>; Frames: Integer);
begin
  if Length(FPCM) + Length(PCM) > FInfo.SampleRate * 4 then
    raise EInvalidOpException.Create('GBS PCM queue exceeds two seconds');
  if Length(FPCM) = 0 then
    FRead := 0;
  if Length(FPCM) = 0 then
    FRead := 0;
  FPCM := FPCM + PCM;
end;

procedure TGBSDecoder.CallRoutine(Address: Word);
begin
  var Start := FCPU.Cycles;
  FCPU.StackPointer := (FCPU.StackPointer - 2) and $FFFF;
  FMemory.WriteWord(FCPU.StackPointer, $100);
  FCPU.ProgramCounter := Address;
  repeat
    FCPU.Step;
    // INIT / PLAY cannot leave interrupts enabled outside their own calls.
    if FCPU.Cycles - Start > 4194304 * 2 then
      raise EInvalidOpException.Create('GBS INIT/PLAY did not return within two seconds');
    // INIT can produce many blocks; discard them before the first render.
    if not FReady then
      FPCM := nil;
  until FCPU.ProgramCounter = $100;
end;

function TGBSDecoder.Period: Integer;
const
  Dividers: array[0..3] of Integer = (1024, 16, 64, 256);
begin
  if (FTimer.GetControl and 4) = 0 then
    Exit(70224);
  Result := Dividers[FTimer.GetControl and 3] * (256 - FTimer.GetModulo);
  if FMemory.Fast then
    Result := Max(1, Result div 2);
end;

procedure TGBSDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Invalid GBS track');
  FReady := False;
  ReleaseMachine;
  FPCM := nil;
  FRead := 0;
  FIRQ := TGBInterruptManager.Create;
  FTimer := TGBTimer.Create(FIRQ, True);
  FJoy := TGBJoypad.Create(FIRQ);
  // LCD stays disabled: no rendering or VBlank callbacks are needed.
  FGPU := TGBGPU.Create(nil);
  FMemory := TGBSMemory.Create(nil, FGPU, FTimer, FIRQ, FJoy);
  FMemory.UseBIOS := False;
  FMemory.Bank := 1;
  FMemory.Fast := (FData[$F] and $80) <> 0;
  var Load := LE16(FData, 6);
  SetLength(FMemory.ROM, Max($8000, ((Length(FData) - $70 + Load + $3FFF) div $4000) * $4000));
  Move(FData[$70], FMemory.ROM[Load], Length(FData) - $70);
  for var Vector := 0 to 7 do
  begin
    FMemory.ROM[Vector * 8] := $C3;
    FMemory.ROM[Vector * 8 + 1] := (Load + Vector * 8) and $FF;
    FMemory.ROM[Vector * 8 + 2] := (Load + Vector * 8) shr 8;
  end;
  FMemory.ROM[$40] := $D9;
  FMemory.ROM[$50] := $D9;
  FSound := TGBSound.Create(FMemory, False);
  FSound.OnPCM := ReceivePCM;
  FCPU := TGBCPU.Create(FMemory, FGPU, FSound);
  FCPU.StackPointer := LE16(FData, $C);
  FCPU.SetRegisterA(Index);
  FMemory.WriteByte($FF26, $80);
  FMemory.WriteByte($FF24, $77);
  FMemory.WriteByte($FF25, $FF);
  FTimer.SetModulo(FData[$E]);
  FTimer.SetCounter(FData[$E]);
  FTimer.SetControl(FData[$F] and 7);
  CallRoutine(LE16(FData, 8));
  FPCM := nil;
  FNextPlay := FCPU.Cycles;
  FReady := True;
end;

function TGBSDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  if not FReady then
    raise EInvalidOpException.Create('Select a track before rendering');
  Result := 0;
  while Result < Frames do
  begin
    if Length(FPCM) = 0 then
    begin
      if FCPU.Cycles >= FNextPlay then
      begin
        CallRoutine(LE16(FData, $A));
        FNextPlay := FNextPlay + UInt64(Period);
        if FNextPlay < FCPU.Cycles then
          FNextPlay := FCPU.Cycles;
      end
      else
        FCPU.ConsumeClockCycles(4);
      Continue;
    end;
    var N := Min(Frames - Result, Length(FPCM) div 2 - FRead);
    Move(FPCM[FRead * 2], Samples[Result * 2], N * 4);
    Inc(FRead, N);
    Inc(Result, N);
    if FRead = Length(FPCM) div 2 then
      FPCM := nil;
  end;
end;

function CreateGBS(const Data: TBytes): ITuneDecoder;
begin
  Result := TGBSDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.gbs', 'Game Boy Sound', CreateGBS);

end.

