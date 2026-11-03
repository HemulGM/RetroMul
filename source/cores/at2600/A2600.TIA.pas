unit A2600.TIA;

interface

uses
  System.Classes, System.SysUtils, System.UITypes, A2600.Types, HW.Sound.TIA,
  Core.Emulation.Types, Core.Snapshots, A2600.Paddle;

type
  TA2600PixelObjects = record
    Player0, Player1, Missile0, Missile1, Ball, Playfield: Boolean;
  end;

  TA2600TIAState = record
    Registers: array[0..63] of Byte;
    Collision: array[0..7] of Byte;
    ObjectPositions: array[0..4] of Integer;
    DelayedPlayers: array[0..1] of Byte;
    DelayedBall: Byte;
    HorizontalClock, Line: Integer;
    Waiting, FrameReady: Boolean;
    FrameNumber: UInt64;
  end;

  TA2600TIA = class
  private
    FState: TA2600TIAState;
    FSound: TTIASound;
    FPaddles: TA2600PaddleCircuit;
    FPAL, FVideoEnabled: Boolean;
    FFrame: TEmulatorFrame;
    FPalette: TA2600Palette;
    procedure Pixel;
    procedure UpdateMissilePositions;
    function PlayfieldVisible(X: Integer): Boolean;
    procedure UpdateCollisions(const Objects: TA2600PixelObjects);
    function ResolveColor(X: Integer; const Objects: TA2600PixelObjects): Byte;
    procedure StorePixel(X, Y: Integer; Color: TAlphaColor);
    function PlayerOn(Index, X: Integer; Missile: Boolean): Boolean;
    function GetWaiting: Boolean;
    function GetFrameReady: Boolean;
  public
    constructor Create(PAL: Boolean; VideoEnabled: Boolean = True);
    destructor Destroy; override;
    procedure Reset;
    procedure Clock;
    procedure BeginFrame;
    procedure FinishFrame;
    function Read(Index, Bus: Byte; Fire0, Fire1: Boolean): Byte;
    procedure Write(Index, Value: Byte);
    procedure ValidateState;
    procedure SerializePresentation(State: TStateArchive);
    procedure SetPaddleResistance(Index, Ohms: Integer);
    procedure SerializeInputs(State: TStateArchive);
    procedure ResetPaddleInputs;
    property Waiting: Boolean read GetWaiting;
    property FrameReady: Boolean read GetFrameReady;
    property Frame: TEmulatorFrame read FFrame;
    property Sound: TTIASound read FSound;
    property SnapshotState: TA2600TIAState read FState write FState;
  end;

implementation

uses
  A2600.Palette;

const
  TIA_VSYNC = $00;
  TIA_VBLANK = $01;
  TIA_WSYNC = $02;
  TIA_RSYNC = $03;
  TIA_NUSIZ0 = $04;
  TIA_NUSIZ1 = $05;
  TIA_COLUP0 = $06;
  TIA_COLUP1 = $07;
  TIA_COLUPF = $08;
  TIA_COLUBK = $09;
  TIA_CTRLPF = $0A;
  TIA_REFP0 = $0B;
  TIA_REFP1 = $0C;
  TIA_PF0 = $0D;
  TIA_PF1 = $0E;
  TIA_PF2 = $0F;
  TIA_RESP0 = $10;
  TIA_RESP1 = $11;
  TIA_RESM0 = $12;
  TIA_RESM1 = $13;
  TIA_RESBL = $14;
  TIA_AUDC0 = $15;
  TIA_AUDV1 = $1A;
  TIA_GRP0 = $1B;
  TIA_GRP1 = $1C;
  TIA_ENAM0 = $1D;
  TIA_ENAM1 = $1E;
  TIA_ENABL = $1F;
  TIA_HMP0 = $20;
  TIA_HMBL = $24;
  TIA_VDELP0 = $25;
  TIA_VDELP1 = $26;
  TIA_VDELBL = $27;
  TIA_RESMP0 = $28;
  TIA_RESMP1 = $29;
  TIA_HMOVE = $2A;
  TIA_HMCLR = $2B;
  TIA_CXCLR = $2C;

constructor TA2600TIA.Create(PAL: Boolean; VideoEnabled: Boolean);
begin
  inherited Create;
  FPAL := PAL;
  FVideoEnabled := VideoEnabled;
  FSound := TTIASound.Create(A2600CPUClock(PAL));
  FPaddles := TA2600PaddleCircuit.Create(A2600CPUClock(PAL) * 3);
  BuildA2600Palette(PAL, FPalette);
  FFrame.Width := A2600FrameWidth;
  FFrame.Height := 240;
  if PAL then
    FFrame.Height := 288;
  SetLength(FFrame.Pixels, FFrame.Width * FFrame.Height);
  Reset;
end;

destructor TA2600TIA.Destroy;
begin
  FSound.Free;
  FPaddles.Free;
  inherited;
end;

procedure TA2600TIA.Reset;
begin
  FillChar(FState, SizeOf(FState), 0);
  FSound.Reset;
  FPaddles.Reset;
  FFrame.FrameNumber := 0;
  FFrame.Pixels := Copy(FFrame.Pixels);
  for var I := 0 to High(FFrame.Pixels) do
    FFrame.Pixels[I] := $FF000000;
end;

function TA2600TIA.GetWaiting: Boolean;
begin
  Result := FState.Waiting;
end;

function TA2600TIA.GetFrameReady: Boolean;
begin
  Result := FState.FrameReady;
end;

procedure TA2600TIA.BeginFrame;
begin
  // Published frames belong to the frontend until it releases them.
  FFrame.Pixels := Copy(FFrame.Pixels);
  FState.FrameReady := False;
end;

procedure TA2600TIA.StorePixel(X, Y: Integer; Color: TAlphaColor);
begin
  if not FVideoEnabled or (Y < 0) or (Y >= FFrame.Height) then
    Exit;
  FFrame.Pixels[Y * A2600FrameWidth + X * 2] := Color;
  FFrame.Pixels[Y * A2600FrameWidth + X * 2 + 1] := Color;
end;

function TA2600TIA.Read(Index, Bus: Byte; Fire0, Fire1: Boolean): Byte;
begin
  Index := Index and 15;
  Result := Bus;
  if Index < 8 then
    Result := (Bus and $3F) or FState.Collision[Index]
  else if Index < 12 then
  begin
    Result := Bus and $7F;
    if FPaddles.Read(Index - 8) then
      Result := Result or $80;
  end
  else if Index < 14 then
  begin
    Result := Bus and $7F;
    if ((Index = 12) and not Fire0) or ((Index = 13) and not Fire1) then
      Result := Result or $80;
  end;
end;

procedure TA2600TIA.FinishFrame;
begin
  Inc(FState.FrameNumber);
  FState.FrameReady := True;
  FFrame.FrameNumber := FState.FrameNumber;
  FFrame.FramesPerSecond := A2600FrameRate(FPAL);
  FState.Line := 0;
end;

procedure TA2600TIA.Write(Index, Value: Byte);
begin
  case Index of
    TIA_VBLANK:
      FPaddles.SetDump(Value and $80 <> 0);
    TIA_VSYNC:
      if (Value and 2 <> 0) and (FState.Registers[TIA_VSYNC] and 2 = 0) and (FState.Line > 100) then
        FinishFrame;
    TIA_WSYNC:
      FState.Waiting := True;
    TIA_RSYNC:
      FState.HorizontalClock := 0;
    TIA_RESP0..TIA_RESBL:
      begin
        var X := FState.HorizontalClock - 68 + 5;
        if FState.HorizontalClock < 68 then
          X := 3;
        if Index > TIA_RESP1 then
          Dec(X, 1);
        FState.ObjectPositions[Index - TIA_RESP0] := (X + 160) mod 160;
      end;
    TIA_GRP0:
      FState.DelayedPlayers[1] := FState.Registers[TIA_GRP1];
    TIA_GRP1:
      begin
        FState.DelayedPlayers[0] := FState.Registers[TIA_GRP0];
        FState.DelayedBall := FState.Registers[TIA_ENABL];
      end;
    TIA_HMOVE:
      begin
        for var i := 0 to 4 do
        begin
          var Motion := Integer(FState.Registers[TIA_HMP0 + i] shr 4);
          if Motion >= 8 then
            Dec(Motion, 16);
          FState.ObjectPositions[i] := (FState.ObjectPositions[i] - Motion + 160) mod 160;
        end;
      end;
    TIA_HMCLR:
      for var i := TIA_HMP0 to TIA_HMBL do
        FState.Registers[i] := 0;
    TIA_CXCLR:
      FillChar(FState.Collision, SizeOf(FState.Collision), 0);
  end;
  FState.Registers[Index] := Value;
  if (Index >= TIA_AUDC0) and (Index <= TIA_AUDV1) then
    FSound.WriteRegister(Index, Value);
end;

function TA2600TIA.PlayerOn(Index, X: Integer; Missile: Boolean): Boolean;
const
  Copies: array[0..7, 0..2] of Integer =
    ((0, -1, -1), (0, 16, -1), (0, 32, -1), (0, 16, 32), (0, 64, -1), (0, -1, -1), (0, 32, 64), (0, -1, -1));
begin
  Result := False;
  var N := FState.Registers[TIA_NUSIZ0 + Index] and 7;
  var Scale := 1;
  var Position := FState.ObjectPositions[Index];
  if not Missile then
  begin
    if N = 5 then
      Scale := 2;
    if N = 7 then
      Scale := 4;
  end
  else
  begin
    if (FState.Registers[TIA_ENAM0 + Index] and 2 = 0) or (FState.Registers[TIA_RESMP0 + Index] and 2 <> 0) then
      Exit;
    Position := FState.ObjectPositions[2 + Index];
    Scale := 1 shl ((FState.Registers[TIA_NUSIZ0 + Index] shr 4) and 3);
  end;
  for var i := 0 to 2 do
    if Copies[N, i] >= 0 then
    begin
      var D := (X - Position - Copies[N, i] + 320) mod 160;
      if Missile then
      begin
        if D < Scale then
          Exit(True);
      end
      else if D < 8 * Scale then
      begin
        var G := FState.Registers[TIA_GRP0 + Index];
        if FState.Registers[TIA_VDELP0 + Index] and 1 <> 0 then
          G := FState.DelayedPlayers[Index];
        var Bit := D div Scale;
        if FState.Registers[TIA_REFP0 + Index] and 8 = 0 then
          Bit := 7 - Bit;
        if G and (1 shl Bit) <> 0 then
          Exit(True);
      end;
    end;
end;

procedure TA2600TIA.UpdateMissilePositions;
begin
  for var i := 0 to 1 do
    if FState.Registers[TIA_RESMP0 + i] and 2 <> 0 then
    begin
      var Width := 8;
      if FState.Registers[TIA_NUSIZ0 + i] and 7 = 5 then
        Width := 16;
      if FState.Registers[TIA_NUSIZ0 + i] and 7 = 7 then
        Width := 32;
      FState.ObjectPositions[2 + i] := (FState.ObjectPositions[i] + Width div 2) mod 160;
    end;
end;

function TA2600TIA.PlayfieldVisible(X: Integer): Boolean;
begin
  var B := X div 4;
  if B >= 20 then
  begin
    B := B - 20;
    if FState.Registers[TIA_CTRLPF] and 1 <> 0 then
      B := 19 - B;
  end;
  if B < 4 then
    Result := FState.Registers[TIA_PF0] and (1 shl (B + 4)) <> 0
  else if B < 12 then
    Result := FState.Registers[TIA_PF1] and (1 shl (11 - B)) <> 0
  else
    Result := FState.Registers[TIA_PF2] and (1 shl (B - 12)) <> 0;
end;

procedure TA2600TIA.UpdateCollisions(const Objects: TA2600PixelObjects);
begin
  if Objects.Missile0 and Objects.Player1 then
    FState.Collision[0] := FState.Collision[0] or $80;
  if Objects.Missile0 and Objects.Player0 then
    FState.Collision[0] := FState.Collision[0] or $40;
  if Objects.Missile1 and Objects.Player0 then
    FState.Collision[1] := FState.Collision[1] or $80;
  if Objects.Missile1 and Objects.Player1 then
    FState.Collision[1] := FState.Collision[1] or $40;
  if Objects.Player0 and Objects.Playfield then
    FState.Collision[2] := FState.Collision[2] or $80;
  if Objects.Player0 and Objects.Ball then
    FState.Collision[2] := FState.Collision[2] or $40;
  if Objects.Player1 and Objects.Playfield then
    FState.Collision[3] := FState.Collision[3] or $80;
  if Objects.Player1 and Objects.Ball then
    FState.Collision[3] := FState.Collision[3] or $40;
  if Objects.Missile0 and Objects.Playfield then
    FState.Collision[4] := FState.Collision[4] or $80;
  if Objects.Missile0 and Objects.Ball then
    FState.Collision[4] := FState.Collision[4] or $40;
  if Objects.Missile1 and Objects.Playfield then
    FState.Collision[5] := FState.Collision[5] or $80;
  if Objects.Missile1 and Objects.Ball then
    FState.Collision[5] := FState.Collision[5] or $40;
  if Objects.Ball and Objects.Playfield then
    FState.Collision[6] := FState.Collision[6] or $80;
  if Objects.Player0 and Objects.Player1 then
    FState.Collision[7] := FState.Collision[7] or $80;
  if Objects.Missile0 and Objects.Missile1 then
    FState.Collision[7] := FState.Collision[7] or $40;
end;

function TA2600TIA.ResolveColor(X: Integer; const Objects: TA2600PixelObjects): Byte;
begin
  Result := FState.Registers[TIA_COLUBK];
  if Objects.Playfield or Objects.Ball then
  begin
    Result := FState.Registers[TIA_COLUPF];
    if Objects.Playfield and (FState.Registers[TIA_CTRLPF] and 6 = 2) then
      Result := FState.Registers[TIA_COLUP0 + Ord(X >= 80)];
  end;
  if (FState.Registers[TIA_CTRLPF] and 4 = 0) or not (Objects.Playfield or Objects.Ball) then
  begin
    if Objects.Player1 or Objects.Missile1 then
      Result := FState.Registers[TIA_COLUP1];
    if Objects.Player0 or Objects.Missile0 then
      Result := FState.Registers[TIA_COLUP0];
  end;
end;

procedure TA2600TIA.Pixel;
var
  Objects: TA2600PixelObjects;
begin
  var X := FState.HorizontalClock - 68;
  if (X < 0) or (X >= 160) then
    Exit;
  var Y := FState.Line - 40;
  if FPAL then
    Y := FState.Line - 48;
  if (FState.Registers[TIA_VBLANK] and 2 <> 0) or (FState.Registers[TIA_VSYNC] and 2 <> 0) then
  begin
    StorePixel(X, Y, $FF000000);
    Exit;
  end;
  UpdateMissilePositions;
  Objects.Player0 := PlayerOn(0, X, False);
  Objects.Player1 := PlayerOn(1, X, False);
  Objects.Missile0 := PlayerOn(0, X, True);
  Objects.Missile1 := PlayerOn(1, X, True);
  var Ball := FState.Registers[TIA_ENABL];
  if FState.Registers[TIA_VDELBL] and 1 <> 0 then
    Ball := FState.DelayedBall;
  Objects.Ball := (Ball and 2 <> 0) and
    (((X - FState.ObjectPositions[4] + 160) mod 160) < (1 shl ((FState.Registers[TIA_CTRLPF] shr 4) and 3)));
  Objects.Playfield := PlayfieldVisible(X);
  UpdateCollisions(Objects);
  StorePixel(X, Y, FPalette[ResolveColor(X, Objects) shr 1]);
end;

procedure TA2600TIA.Clock;
begin
  FPaddles.Clock;
  Pixel;
  Inc(FState.HorizontalClock);
  if FState.HorizontalClock >= A2600ClocksPerLine then
  begin
    FState.HorizontalClock := 0;
    FState.Waiting := False;
    Inc(FState.Line);
    if FState.Line >= A2600MaxFrameLines then
      FinishFrame;
  end;
end;

procedure TA2600TIA.SetPaddleResistance(Index, Ohms: Integer);
begin
  FPaddles.SetResistance(Index, Ohms);
end;

procedure TA2600TIA.ResetPaddleInputs;
begin
  FPaddles.Reset;
  FPaddles.SetDump(FState.Registers[TIA_VBLANK] and $80 <> 0);
end;

procedure TA2600TIA.SerializeInputs(State: TStateArchive);
begin
  FPaddles.SerializeState(State);
end;

procedure TA2600TIA.ValidateState;
begin
  if (FState.HorizontalClock < 0) or (FState.HorizontalClock >= A2600ClocksPerLine) or
    (FState.Line < 0) or (FState.Line > A2600MaxFrameLines) then
    raise EReadError.Create('Invalid Atari 2600 video state');
end;

procedure TA2600TIA.SerializePresentation(State: TStateArchive);
begin
  FSound.SerializeState(State);
  FFrame.Pixels := Copy(FFrame.Pixels);
  State.Field(FFrame.Pixels[0], Length(FFrame.Pixels) * SizeOf(TAlphaColor));
  FFrame.FrameNumber := FState.FrameNumber;
end;

end.

