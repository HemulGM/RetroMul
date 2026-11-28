unit S18.Console;

interface

uses
  System.SysUtils, SegaArcade.Console, SegaArcade.Video, S18.Video, S32.Sound,
  Core.Snapshots;

type
  TS18Console = class(TSegaArcadeConsole)
  private
    FAudio: TS32Sound;
    FPorts: array[0..7] of Byte;
    FPortDirection, FCNT: Byte;
    FADC, FADCPlayer: Byte;
    FTrackball, FTrackballOrigin: array[0..2, 0..1] of Word;
    FGunPosition: array[0..2, 0..1] of Byte;
    function ArcadeVideo: TS18Video; inline;
    function ROMWindow: Cardinal;
    function VDPTime: Int64;
    procedure SoundReply(Sender: TObject);
    function PlayerPort(Player: Integer): Byte;
    function ServicePort: Byte;
    function GunButtons: Byte;
    function ReadPlayerExpansion(RegisterIndex: Integer): Byte;
    procedure WritePlayerExpansion(RegisterIndex: Integer; Value: Byte);
    function ReadExpansion(Offset: Cardinal): Word;
    procedure WriteExpansion(Offset: Cardinal; Value: Byte);
    procedure DrivePort(Port, Value: Byte);
    procedure SwitchBanks(Index, Value: Integer);
    procedure UpdateTrackballs;
    procedure UpdateGunPositions;
  protected
    function CreateVideo: TSegaArcadeVideo; override;
    procedure CreateAudio; override;
    procedure ResetAudio; override;
    procedure CommandAudio(Value: Byte); override;
    function ReplyAudio: Byte; override;
    procedure BeginAudioFrame; override;
    procedure EndAudioFrame; override;
    procedure RunAudio; override;
    procedure SerializeAudio(State: TStateArchive); override;
    function ReadAchievementSoundRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal; override;
    procedure SerializeBoardState(State: TStateArchive); override;
    procedure StartScanline(Line: Integer); override;
    procedure EndScanline(Line: Integer); override;
    function HasNVRAM: Boolean; override;
    function LineDeadline(Line: Integer): Int64; override;
    function DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer; override;
    function ReadIO(Offset: Cardinal): Word; override;
    procedure WriteIO(Offset: Cardinal; Value: Byte); override;
    function MCUPortRead(Port: Byte): Byte; override;
    procedure MCUPortWrite(Port, Value: Byte); override;
    function ExtraRead(Region: Integer; Offset: Cardinal): Word; override;
    procedure ExtraWrite(Region: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean); override;
    procedure WriteROM(Address, Offset: Cardinal; Value: Byte); override;
  public
    destructor Destroy; override;
    procedure Reset; override;
    function AudioSamples: TArray<SmallInt>; override;
    function FrameRate: Double; override;
    procedure AddPointerMotion(DX, DY: Integer); override;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

uses
  System.Classes, System.Math, Core.Emulation.Types;

const
  BoardShadow = 1;
  Board5874 = 2;
  Board5987 = 3;
  Board7525 = 4;
  RegionVDP = 12;
  RegionBankRegister = 13;
  RegionEmptyROM = 14;
  MainClock = 10000000;
  RefreshNumerator = 5723;
  RefreshDenominator = 100;
  LinesPerFrame = 262;
  VDPTicksPerLine = 3420;

function DMARead(UserData: Pointer; Address, TargetCycle: Cardinal): Cardinal;
begin
  Result := TS18Console(UserData).ReadWord(Address);
end;

function TS18Console.ArcadeVideo: TS18Video;
begin
  Result := TS18Video(Video);
end;

function TS18Console.CreateVideo: TSegaArcadeVideo;
begin
  Result := TS18Video.Create(FCart['tiles'], FCart['sprites']);
end;

procedure TS18Console.CreateAudio;
begin
  FAudio := TS32Sound.Create(FCart['soundcpu'], True);
  FAudio.OnReply := SoundReply;
end;

destructor TS18Console.Destroy;
begin
  FAudio.Free;
  inherited;
end;

procedure TS18Console.Reset;
begin
  FillChar(FPorts, SizeOf(FPorts), 0);
  FPortDirection := 0;
  FCNT := 0;
  FADC := 0;
  FADCPlayer := 1;
  FillChar(FTrackball, SizeOf(FTrackball), 0);
  FillChar(FTrackballOrigin, SizeOf(FTrackballOrigin), 0);
  FillChar(FGunPosition, SizeOf(FGunPosition), $80);
  ArcadeVideo.ResetVDP;
  inherited;
  FPPI[3] := $9B; // 8255 starts with all ports configured as inputs.
  DrivePort(7, 0);
end;

function TS18Console.HasNVRAM: Boolean;
begin
  Result := True;
end;

function TS18Console.FrameRate: Double;
begin
  Result := RefreshNumerator / RefreshDenominator;
end;

function TS18Console.LineDeadline(Line: Integer): Int64;
begin
  const CyclesPerPeriod = Int64(MainClock) * RefreshDenominator;
  var Lines := (FFrameNumber mod RefreshNumerator) * LinesPerFrame + Line + 1;
  Result := (FFrameNumber div RefreshNumerator) * CyclesPerPeriod +
    Lines * CyclesPerPeriod div (RefreshNumerator * LinesPerFrame);
end;

function TS18Console.VDPTime: Int64;
begin
  const Divisor = MainClock * Int64(RefreshDenominator);
  // The host VDP counters use a 3420-tick line even in untimed-access mode.
  Result := ((FTime mod Divisor) * (RefreshNumerator * LinesPerFrame * Int64(VDPTicksPerLine))) div Divisor;
end;

procedure TS18Console.StartScanline(Line: Integer);
begin
  if Line = 0 then
  begin
    if FCart.RomSet.Inputs.StartsWith('wwally') then
      UpdateTrackballs
    else if FCart.RomSet.Inputs = 'lghost' then
      UpdateGunPositions;
  end;
  ArcadeVideo.BeginScanline(Line);
end;

procedure TS18Console.EndScanline(Line: Integer);
begin
  ArcadeVideo.EndScanline(Line);
end;

function TS18Console.ROMWindow: Cardinal;
begin
  Result := $80000;
  if (FCart.RomSet.Board = Board5987) and (Length(FProgram) > $100000) then
    Result := $100000;
end;

function TS18Console.DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer;
const
  SizeMask: array[0..3] of Cardinal = ($FFFF, $1FFFF, $7FFFF, $1FFFFF);
begin
  var Board := FCart.RomSet.Board;
  var Window := ROMWindow;
  for var Region := 0 to 7 do
  begin
    var Mask := SizeMask[FMapper[$10 + Region * 2] and 3];
    if (Address and not Mask) <> ((Cardinal(FMapper[$11 + Region * 2]) shl 16) and not Mask) then
      Continue;
    var local := Address and Mask;
    case Region of
      0, 1, 2:
        begin
          if ((Board = BoardShadow) and (Region = 1)) or
            ((Board <> BoardShadow) and (Region = 2)) then
          begin
            Offset := local and $F;
            Exit(RegionVDP);
          end;
          if Region = 2 then
            Continue;
          Offset := (local and (Window - 1)) + Cardinal(Region) * Window;
          if Offset < Cardinal(Length(FProgram)) then
            Exit(0);
          if (Region = 1) and (Board in [Board5987, Board7525]) then
            Exit(RegionBankRegister);
          Exit(RegionEmptyROM);
        end;
      3:
        Offset := local and $3FFF;
      4:
        Offset := local and $7FF;
      5:
        begin
          Offset := local and $1FFFF;
          if Offset >= $10000 then
          begin
            Offset := Offset and $FFF;
            Exit(8);
          end;
        end;
      6:
        Offset := local and $FFF;
      7:
        Offset := local and $3FFF;
    end;
    Exit(Region);
  end;
  Offset := 0;
  Result := -1;
end;

procedure TS18Console.SwitchBanks(Index, Value: Integer);
begin
  case FCart.RomSet.Board of
    Board5987:
      if Index < 8 then
        ArcadeVideo.SetTileBank(Index, Value, True)
      else
        ArcadeVideo.SetSpritePair(Index - 8, Value);
    Board7525:
      if Index < 8 then
      begin
        var Bank := Value and $1F;
        if Value and $80 <> 0 then
          Inc(Bank, $20);
        ArcadeVideo.SetTileBank(Index, Bank);
      end;
  end;
end;

procedure TS18Console.WriteROM(Address, Offset: Cardinal; Value: Byte);
begin
  if Offset >= ROMWindow then
    SwitchBanks((Offset shr 1) and $F, Value);
end;

function TS18Console.ExtraRead(Region: Integer; Offset: Cardinal): Word;
begin
  if Region = RegionVDP then
    Exit(ArcadeVideo.ReadVDP(Offset, VDPTime));
  Result := $FFFF;
end;

procedure TS18Console.ExtraWrite(Region: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  case Region of
    RegionVDP:
      begin
        if not HighByte then
          Value := (Value and $FF) * $101
        else if not LowByte then
          Value := (Value shr 8) * $101;
        ArcadeVideo.WriteVDP(Offset, Value, VDPTime, DMARead, Self);
      end;
    RegionBankRegister:
      if LowByte then
        SwitchBanks((Offset shr 1) and $F, Value and $FF);
  end;
end;

function TS18Console.PlayerPort(Player: Integer): Byte;
const
  Buttons: array[0..7] of TEmulatorButton = (TEmulatorButton.A, TEmulatorButton.B,
    TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.Down,
    TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Left);
begin
  var Pressed := FInput.PortButtons(Player);
  Result := $FF;
  if FCart.RomSet.Inputs.StartsWith('wwally') then
  begin
    if TEmulatorButton.A in Pressed then
      Result := Result xor $01;
    if (Player = 0) and (FCart.RomSet.Inputs = 'wwally3p') and
      (TEmulatorButton.A in FInput.Buttons3) then
      Result := Result xor $04;
    Exit;
  end;
  for var BitIndex := 0 to 7 do
    if (Buttons[BitIndex] in Pressed) and
      ((BitIndex <> 3) or ((Player = 2) and (FCart.RomSet.Inputs <> 'astorm'))) then
      Result := Result xor (1 shl BitIndex);
end;

function TS18Console.ServicePort: Byte;
begin
  var Layout := FCart.RomSet.Inputs;
  var Coin1Mask := $01;
  var Coin3Mask := 0;
  if (Layout = 'astorm') or (Layout = 'ddcrew3p') or
    ((Layout = 'mwalk') and (DIP[1] and $20 = 0)) or
    ((Layout = 'mwalka') and (DIP[1] and $20 <> 0)) then
  begin
    Coin1Mask := $80;
    Coin3Mask := $01;
  end
  else if (Layout = 'desertbr') or (Layout = 'lghost') then
    Coin3Mask := $80
  else if (Layout = 'wwally3p') and (DIP[1] and $04 <> 0) then
  begin
    Coin1Mask := $40;
    Coin3Mask := $01;
  end;

  Result := $FF;
  if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
    Result := Result xor Coin1Mask;
  if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
    Result := Result and $FD;
  if TEmulatorButton.Select in FInput.Buttons3 then
    Result := Result xor Coin3Mask;
  if TEmulatorButton.Mode in FInput.Buttons then
    Result := Result and $FB;
  if TEmulatorButton.Start in FInput.Buttons then
    Result := Result and $EF;
  if TEmulatorButton.Start in FInput.Buttons2 then
    Result := Result and $DF;
  if TEmulatorButton.Start in FInput.Buttons3 then
    if (Layout = 'astorm') or (Layout = 'lghost') then
      Result := Result and $BF
    else if Layout = 'wwally3p' then
      Result := Result and $7F;
end;

function TS18Console.GunButtons: Byte;
const
  FireBits: array[0..2] of Byte = ($01, $04, $80);
  SpecialBits: array[0..2] of Byte = ($02, $08, $40);
begin
  Result := $FF;
  for var I := 0 to 2 do
  begin
    var Buttons := FInput.PortButtons(I);
    if TEmulatorButton.A in Buttons then
      Result := Result xor FireBits[I];
    if TEmulatorButton.B in Buttons then
      Result := Result xor SpecialBits[I];
  end;
end;

function TS18Console.ReadIO(Offset: Cardinal): Word;
const
  Signature: array[8..11] of Byte = (Ord('S'), Ord('E'), Ord('G'), Ord('A'));
begin
  case Offset and $3000 of
    $2000:
      Exit($FFFF);
    $3000:
      Exit(ReadExpansion(Offset));
  end;
  var Port := (Offset shr 1) and $3F;
  Result := $FFFF;
  case Port of
    0..7:
      if FPortDirection and (1 shl Port) <> 0 then
        Result := $FF00 or FPorts[Port]
      else
        case Port of
          0, 1:
            if FCart.RomSet.Inputs = 'lghost' then
            begin
              if Port = 0 then
                Result := $FF00 or GunButtons;
            end
            else
              Result := $FF00 or PlayerPort(Port);
          2:
            if (FCart.RomSet.Inputs = 'astorm') or (FCart.RomSet.Inputs = 'ddcrew3p') or
              (FCart.RomSet.Inputs = 'mwalk') or (FCart.RomSet.Inputs = 'mwalka') or
              (FCart.RomSet.Inputs = 'desertbr') then
              Result := $FF00 or PlayerPort(2);
          4:
            Result := $FF00 or ServicePort;
          5:
            Result := $FF00 or DIP[0];
          6:
            Result := $FF00 or DIP[1];
        end;
    8..11:
      Result := $FF00 or Signature[Port];
    12, 14:
      Result := $FF00 or FCNT;
    13, 15:
      Result := $FF00 or FPortDirection;
  end;
end;

procedure TS18Console.DrivePort(Port, Value: Byte);
begin
  case Port of
    3:
      begin
        Video.Flip := Value and $20 <> 0;
        ArcadeVideo.Grayscale := Value and $40 = 0;
      end;
    7:
      if FCart.RomSet.Board in [BoardShadow, Board5874] then
        for var Bank := 0 to 3 do
        begin
          ArcadeVideo.SetTileBank(Bank, (Value and $F) * 4 + Bank);
          ArcadeVideo.SetTileBank(Bank + 4, (Value shr 4) * 4 + Bank);
        end;
  end;
end;

procedure TS18Console.WriteIO(Offset: Cardinal; Value: Byte);
begin
  case Offset and $3000 of
    $2000:
      begin
        ArcadeVideo.Mixing := Value;
        Exit;
      end;
    $3000:
      begin
        WriteExpansion(Offset, Value);
        Exit;
      end;
  end;
  var Port := (Offset shr 1) and $3F;
  case Port of
    0..7:
      begin
        FPorts[Port] := Value;
        if FPortDirection and (1 shl Port) <> 0 then
          DrivePort(Port, Value);
      end;
    14:
      begin
        FCNT := Value;
        Video.DisplayEnabled := Value and 2 <> 0;
        ArcadeVideo.OverlayEnabled := Value and 4 <> 0;
      end;
    15:
      begin
        var Changed := FPortDirection xor Value;
        FPortDirection := Value;
        for var I := 0 to 7 do
          if Changed and (1 shl I) <> 0 then
            if Value and (1 shl I) <> 0 then
              DrivePort(I, FPorts[I])
            else
              DrivePort(I, 0);
      end;
  end;
end;

function TS18Console.ReadPlayerExpansion(RegisterIndex: Integer): Byte;
begin
  Result := FPPI[RegisterIndex];
  case RegisterIndex of
    0:
      if FPPI[3] and $10 <> 0 then
        Result := PlayerPort(2);
    1:
      if FPPI[3] and 2 <> 0 then
        Result := PlayerPort(3);
    2:
      begin
        var InputBits := $FF;
        for var I := 0 to 1 do
        begin
          var Buttons := FInput.PortButtons(I + 2);
          if TEmulatorButton.Start in Buttons then
            InputBits := InputBits xor (1 shl I);
          if TEmulatorButton.Select in Buttons then
            InputBits := InputBits xor (4 shl I);
        end;
        if FPPI[3] and 1 <> 0 then
          Result := (Result and $F0) or (InputBits and $F);
        if FPPI[3] and 8 <> 0 then
          Result := Result or $F0;
      end;
  end;
end;

procedure TS18Console.WritePlayerExpansion(RegisterIndex: Integer; Value: Byte);
begin
  if RegisterIndex < 3 then
    FPPI[RegisterIndex] := Value
  else if Value and $80 <> 0 then
  begin
    FPPI[3] := Value;
    for var I := 0 to 2 do
      FPPI[I] := 0;
  end
  else
  begin
    var Mask := 1 shl ((Value shr 1) and 7);
    if Value and 1 <> 0 then
      FPPI[2] := FPPI[2] or Mask
    else
      FPPI[2] := FPPI[2] and not Mask;
  end;
end;

function TS18Console.ReadExpansion(Offset: Cardinal): Word;
begin
  var Layout := FCart.RomSet.Inputs;
  if (Layout = 'ddcrew4p') and (Offset >= $3020) and (Offset <= $3024) then
    Exit(ReadPlayerExpansion((Offset - $3020) shr 1));
  if (Layout = 'lghost') and (Offset >= $3010) and (Offset <= $3016) then
  begin
    Result := $7F or (FADC and $80);
    FADC := (FADC shl 1) and $FF;
    Exit;
  end;
  if Layout.StartsWith('wwally') and (Offset < $3018) then
  begin
    var Player := Integer((Offset - $3000) shr 3);
    var Axis := Integer((Offset shr 2) and 1);
    var Position := (Integer(FTrackball[Player, Axis]) - FTrackballOrigin[Player, Axis]) and $FFF;
    if Offset and 2 = 0 then
      Exit(Position and $FF);
    Exit(Position shr 8);
  end;
  Result := $FFFF;
end;

procedure TS18Console.WriteExpansion(Offset: Cardinal; Value: Byte);
begin
  var Layout := FCart.RomSet.Inputs;
  if (Layout = 'ddcrew4p') and (Offset >= $3020) and (Offset <= $3026) then
    WritePlayerExpansion((Offset - $3020) shr 1, Value)
  else if Layout = 'lghost' then
  begin
    if Offset = $3020 then
      FADCPlayer := 1 + (Value and 1)
    else if (Offset >= $3010) and (Offset <= $3016) then
    begin
      var Player := 0;
      if Offset and 4 <> 0 then
        Player := FADCPlayer;
      if Offset and 2 = 0 then
        FADC := 255 - FGunPosition[Player, 1]
      else
        FADC := FGunPosition[Player, 0];
    end;
  end
  else if Layout.StartsWith('wwally') and (Offset < $3018) then
  begin
    var Player := Integer((Offset - $3000) shr 3);
    FTrackballOrigin[Player, 0] := FTrackball[Player, 0];
    FTrackballOrigin[Player, 1] := FTrackball[Player, 1];
  end;
end;

procedure TS18Console.UpdateTrackballs;
begin
  for var I := 0 to 2 do
  begin
    var Buttons := FInput.PortButtons(I);
    var X := (Ord(TEmulatorButton.Right in Buttons) - Ord(TEmulatorButton.Left in Buttons)) * 7;
    var Y := (Ord(TEmulatorButton.Down in Buttons) - Ord(TEmulatorButton.Up in Buttons)) * 7;
    if FInput.Analog[I].Valid then
    begin
      X := FInput.Analog[I].X div 4096;
      Y := FInput.Analog[I].Y div 4096;
    end;
    FTrackball[I, 0] := (Integer(FTrackball[I, 0]) - X) and $FFF;
    FTrackball[I, 1] := (Integer(FTrackball[I, 1]) + Y) and $FFF;
  end;
end;

procedure TS18Console.AddPointerMotion(DX, DY: Integer);
begin
  FTrackball[0, 0] := (Integer(FTrackball[0, 0]) - DX) and $FFF;
  FTrackball[0, 1] := (Integer(FTrackball[0, 1]) + DY) and $FFF;
end;

procedure TS18Console.UpdateGunPositions;
begin
  for var I := 0 to 2 do
  begin
    var Pad := FInput.Analog[I];
    if Pad.Valid then
    begin
      FGunPosition[I, 0] := (Integer(Pad.X) + 32768) shr 8;
      FGunPosition[I, 1] := (Integer(Pad.Y) + 32768) shr 8;
    end
    else
    begin
      var Buttons := FInput.PortButtons(I);
      var X := Ord(TEmulatorButton.Right in Buttons) - Ord(TEmulatorButton.Left in Buttons);
      var Y := Ord(TEmulatorButton.Down in Buttons) - Ord(TEmulatorButton.Up in Buttons);
      FGunPosition[I, 0] := EnsureRange(Integer(FGunPosition[I, 0]) + X * 5, 0, 255);
      FGunPosition[I, 1] := EnsureRange(Integer(FGunPosition[I, 1]) + Y * 5, 0, 255);
    end;
  end;
end;

function TS18Console.MCUPortRead(Port: Byte): Byte;
begin
  Result := $FF;
end;

procedure TS18Console.MCUPortWrite(Port, Value: Byte);
begin
end;

procedure TS18Console.SoundReply(Sender: TObject);
begin
  if FMCU <> nil then
    FMCU.SetIRQ(1, True);
end;

procedure TS18Console.ResetAudio;
begin
  FAudio.Reset;
end;

procedure TS18Console.CommandAudio(Value: Byte);
begin
  FAudio.Command(Value);
end;

function TS18Console.ReplyAudio: Byte;
begin
  if FMCU <> nil then
    FMCU.SetIRQ(1, False);
  Result := FAudio.Reply;
end;

procedure TS18Console.BeginAudioFrame;
begin
  FAudio.BeginFrame;
end;

procedure TS18Console.EndAudioFrame;
begin
  FAudio.EndFrame;
end;

procedure TS18Console.RunAudio;
begin
  FAudio.RunUntil(FTime * FAudio.Clock div MainClock);
end;

function TS18Console.AudioSamples: TArray<SmallInt>;
begin
  Result := FAudio.Samples;
end;

procedure TS18Console.SerializeAudio(State: TStateArchive);
begin
  FAudio.SerializeState(State);
end;

procedure TS18Console.SerializeBoardState(State: TStateArchive);
var
  UnusedMultiplier: array[0..1] of Word;
  UnusedComparators: array[0..1, 0..15] of Word;
  UnusedCompareHistory: array[0..1] of Integer;
begin
  // Earlier System 18 snapshots include the unused System 16 math registers.
  FillChar(UnusedMultiplier, SizeOf(UnusedMultiplier), 0);
  FillChar(UnusedComparators, SizeOf(UnusedComparators), 0);
  FillChar(UnusedCompareHistory, SizeOf(UnusedCompareHistory), 0);
  State.Field(UnusedMultiplier, SizeOf(UnusedMultiplier));
  State.Field(UnusedComparators, SizeOf(UnusedComparators));
  State.Field(UnusedCompareHistory, SizeOf(UnusedCompareHistory));
end;

procedure TS18Console.SerializeState(State: TStateArchive);
begin
  inherited;
  ArcadeVideo.SerializeVDP(State);
  State.Field(FPorts, SizeOf(FPorts));
  State.Field(FPortDirection, SizeOf(FPortDirection));
  State.Field(FCNT, SizeOf(FCNT));
  State.Field(FADC, SizeOf(FADC));
  State.Field(FADCPlayer, SizeOf(FADCPlayer));
  State.Field(FTrackball, SizeOf(FTrackball));
  State.Field(FTrackballOrigin, SizeOf(FTrackballOrigin));
  State.Field(FGunPosition, SizeOf(FGunPosition));
  if FADCPlayer > 2 then
    raise EReadError.Create('Invalid System 18 ADC state');
end;

function TS18Console.ReadAchievementSoundRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
begin
  Result := ReadAchievementMemoryBlock(Address, Buffer, Count, @FAudio.Shared, SizeOf(FAudio.Shared));
end;

end.

