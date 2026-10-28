unit GW.Console;

interface

uses
  System.SysUtils, Core.Emulation.Types, Core.Snapshots, GW.CPU, GW.Cartridge,
  GW.MGW;

type
  TGWConsoleState = packed record
    FrameNumber: UInt64;
    FramePhase, LCDPhase, AudioPhase: Integer;
    Decay: array[0..255] of Byte;
    DC: Double;
  end;

  TGWConsole = class
  private
    FPersistent: TBytes;
    FCartridge: TGWCartridge; // Owned by adapter; vectors are prepared on the UI thread.
    FCPU: TGWCPU;
    FMGW: TMGWConsole;
    FState: TGWConsoleState;
    FButtons: Cardinal;
    FFrame: TEmulatorFrame;
    FSamples: TArray<SmallInt>;
    function GetFrame: TEmulatorFrame;
    function GetSamples: TArray<SmallInt>;
    procedure ClockInput;
    procedure Render;
  public
    constructor Create(Cartridge: TGWCartridge; const SavedData: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInput(const Input: TEmulatorInput);
    procedure RunFrame;
    procedure SerializeState(Archive: TStateArchive);
    function SavePersistent: TBytes;
    function SupportedButtons: TEmulatorButtons;
    property CPU: TGWCPU read FCPU;
    property Frame: TEmulatorFrame read GetFrame;
    property Samples: TArray<SmallInt> read GetSamples;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TGWConsole.Create(Cartridge: TGWCartridge; const SavedData: TBytes);
begin
  inherited Create;
  FCartridge := Cartridge;
  FPersistent := Copy(SavedData);
  Reset;
end;

destructor TGWConsole.Destroy;
begin
  FMGW.Free;
  FCPU.Free;
  inherited;
end;

function TGWConsole.GetFrame: TEmulatorFrame;
begin
  if FMGW <> nil then
    Result := FMGW.Frame
  else
    Result := FFrame;
end;

function TGWConsole.GetSamples: TArray<SmallInt>;
begin
  if FMGW <> nil then
    Result := FMGW.Samples
  else
    Result := FSamples;
end;

function TGWConsole.SavePersistent: TBytes;
begin
  Result := nil;
  if FMGW <> nil then
    Result := FMGW.SavePersistent;
end;

procedure TGWConsole.Reset;
begin
  if FMGW <> nil then
    FPersistent := FMGW.SavePersistent;
  FreeAndNil(FMGW);
  FreeAndNil(FCPU);
  if FCartridge.MGW <> nil then
  begin
    FMGW := TMGWConsole.Create(FCartridge.MGW, FPersistent);
    Exit;
  end;

  FCPU := TGWCPU.Create(FCartridge.Model, FCartridge.ProgramData, FCartridge.MelodyData, FCartridge.RMask);
  FState := Default(TGWConsoleState);
  FButtons := 0;
  FSamples := nil;
  Render;
end;

function TGWConsole.SupportedButtons: TEmulatorButtons;
begin
  if FMGW <> nil then
    Result := FMGW.SupportedButtons
  else
    Result := FCartridge.SupportedButtons;
end;

procedure TGWConsole.SetInput(const Input: TEmulatorInput);
begin
  if FMGW <> nil then
  begin
    FMGW.SetInput(Input);
    Exit;
  end;

  FButtons := 0;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if Button in Input.Buttons then
      FButtons := FButtons or (Cardinal(1) shl Ord(Button));
    if Button in Input.Buttons2 then
      FButtons := FButtons or (Cardinal(1) shl (16 + Ord(Button)));
  end;
end;

procedure TGWConsole.ClockInput;
begin
  var K: Byte := 0;
  var Mux := FCPU.SOutput;
  if FCartridge.GWInputFallback and (Mux = 0) then
    Mux := 2;
  for var Row := 0 to 7 do
    if ((Mux and (1 shl Row)) <> 0) or (Row = FCartridge.FixedRow) then
      for var Bit := 0 to 3 do
        if (FCartridge.Keys[Row, Bit] and FButtons) <> 0 then
          K := K or (1 shl Bit);
  FCPU.SetInput(K, (FCartridge.BA and FButtons) = 0, (FCartridge.B and FButtons) = 0, K <> 0);
end;

procedure TGWConsole.Render;
begin
  FFrame.Width := FCartridge.Artwork.Width;
  FFrame.Height := FCartridge.Artwork.Height;
  FFrame.FrameNumber := FState.FrameNumber;
  FFrame.FramesPerSecond := 60;
  FFrame.Pixels := Copy(FCartridge.Artwork.Background);
  for var Layer in FCartridge.Artwork.Layers do
  begin
    if FState.Decay[Layer.Index] < FCartridge.DecayPivot then
      Continue;

    for var Y := 0 to Layer.Height - 1 do
      for var X := 0 to Layer.Width - 1 do
      begin
        var P := (Y + Layer.Y) * FFrame.Width + Layer.X + X;
        var Src := Layer.Pixels[Y * Layer.Width + X];
        var Dest := FFrame.Pixels[P];
        var Inv: Cardinal := 255 - (Src shr 24);
        FFrame.Pixels[P] := $FF000000 or
          (Min(Cardinal(255), ((Src shr 16) and 255) + ((Dest shr 16) and 255) * Inv div 255) shl 16) or
          (Min(Cardinal(255), ((Src shr 8) and 255) + ((Dest shr 8) and 255) * Inv div 255) shl 8) or
          Min(Cardinal(255), (Src and 255) + (Dest and 255) * Inv div 255);
      end;
  end;
end;

procedure TGWConsole.RunFrame;
begin
  if FMGW <> nil then
  begin
    FMGW.RunFrame;
    Exit;
  end;

  SetLength(FSamples, 1474);
  var Count := 0;
  Inc(FState.FramePhase, 32768);
  var Clocks := FState.FramePhase div 60;
  FState.FramePhase := FState.FramePhase mod 60;
  for var Tick := 1 to Clocks do
  begin
    ClockInput;
    var Pins := FCPU.Tick;
    Inc(FState.LCDPhase, 1000);
    if FState.LCDPhase >= 32768 then
    begin
      Dec(FState.LCDPhase, 32768);
      for var I := 0 to 255 do
        if FCPU.Segment(I) then
        begin
          if FState.Decay[I] < FCartridge.DecayPivot + FCartridge.DecayLength then
            Inc(FState.Decay[I]);
        end
        else if FState.Decay[I] > 0 then
          Dec(FState.Decay[I]);
    end;
    var Level: Integer;
    case FCartridge.SoundMode of
      2:
        Level := (Pins shr 1) and 1;
      3:
        Level := (Pins and 1) - ((Pins shr 1) and 1);
      4:
        Level := (Pins and 1) - (FCPU.SOutput and 1);
      5:
        Level := (FCPU.SOutput and 1) - (Pins and 1);
    else
      Level := Pins and 1;
    end;
    Inc(FState.AudioPhase, 44100);
    while FState.AudioPhase >= 32768 do
    begin
      Dec(FState.AudioPhase, 32768);
      FState.DC := FState.DC + 0.005 * (Level - FState.DC);
      var Sample := Round((Level - FState.DC) * 10000);
      FSamples[Count] := Sample;
      FSamples[Count + 1] := Sample;
      Inc(Count, 2);
    end;
  end;
  SetLength(FSamples, Count);
  Inc(FState.FrameNumber);
  Render;
end;

procedure TGWConsole.SerializeState(Archive: TStateArchive);
begin
  if FMGW <> nil then
  begin
    FMGW.SerializeState(Archive);
    Exit;
  end;

  // Validate all state before publishing it. CPU validates its own fields.
  var Saved := FState;
  Archive.Field(Saved, SizeOf(Saved));
  if Archive.Loading then
  begin
    if (Saved.FramePhase < 0) or (Saved.FramePhase >= 60) or
      (Saved.LCDPhase < 0) or (Saved.LCDPhase >= 32768) or
      (Saved.AudioPhase < 0) or (Saved.AudioPhase >= 32768) or
      IsNan(Saved.DC) or IsInfinite(Saved.DC) or (Abs(Saved.DC) > 2) then
      raise EReadError.Create('Invalid Game & Watch snapshot');

    for var Value in Saved.Decay do
      if Value > FCartridge.DecayPivot + FCartridge.DecayLength then
        raise EReadError.Create('Invalid LCD persistence state');
  end;
  FCPU.SerializeState(Archive);
  if Archive.Loading then
  begin
    FState := Saved;
    FSamples := nil;
    Render;
  end;
end;

end.

