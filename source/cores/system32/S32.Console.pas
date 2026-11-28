unit S32.Console;

interface

uses
  System.SysUtils, System.UITypes, S32.Cartridge, S32.Video, S32.Sound, HW.V60,
  HW.EEPROM93Cxx, S32.Protection, S32.CD, Core.CD.Disc, S32.BusProtection,
  S32.DriveBoard, S32.IRQ, Core.Emulation, Core.Snapshots;

type
  TS32Console = class
  private
    FROM: TBytes;
    FCart: TS32Cartridge;
    FCPU: TV60;
    FVideo: TS32Video;
    FSound: TS32Sound;
    FEEPROM: TSerialEEPROM93Cxx;
    FProtection: TS32V25Protection;
    FBusProtection: TS32BusProtection;
    FCD: TS32CD;
    FDrive: TS32DriveBoard;
    FCXDData, FCXDDirection: array[0..4] of Byte;
    FCXDReadPC: Cardinal;
    FRAM: TS32WorkRAM;
    FBoardIndex: Integer;
    FSubBoard: TS32Console;
    FLinkRAM: TBytes;
    FSpriteTime: Int64;
    FFramePixels: TArray<TAlphaColor>;
    FAudioSamples: TArray<SmallInt>;
    FFrameWidth: Integer;
    FInterrupts: TS32Interrupts;
    FIO: array[0..7] of Byte;
    FDirection, FCount: Byte;
    FTime, FFrame: Int64;
    FInput: TEmulatorInput;
    FCoins: array[0..3] of Integer;
    FRandom: Cardinal;
    FRandomSeed: Word;
    FADCValue: Byte;
    FSteeringValue: Byte;
    FSteeringDigital: Boolean;
    FSteeringRelative: Boolean;
    FSteeringPhysicalValue: Byte;
    FSteeringPhysicalValid: Boolean;
    FADCBit: Integer;
    FTrack: array[0..2, 0..1] of Word;
    FGearHigh: Boolean;
    function UsesSteeringWheel: Boolean;
    function AnalogAxisValue(PlayerIndex: Integer; Vertical: Boolean): Byte;
    procedure BeginFrame;
    procedure RunUntil(Target: Int64);
    procedure AdvanceCPUClock(Cycles: Integer);
    procedure EndFrame;
    procedure ComposeFrame;
    function NextRandom: Word;
    procedure SeedRandom(Value: Word);
    function IRQVector: Byte;
    procedure SignalIRQ(Source: Integer);
    procedure UpdateIRQ;
    function Player(Index: Integer): Byte;
    function IORead(Index: Integer): Byte;
    procedure IOWrite(Index: Integer; Value: Byte);
    procedure Output(Index: Integer; Value: Byte);
  public
    DIP: array[0..1] of Byte;
    CDPrinterReady: Boolean; // virtual ready line only; paper output is not emulated
    constructor Create(Cart: TS32Cartridge; BoardIndex: Integer = 0; Disc: TCDDisc = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame;
    function ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
    function ReadMemoryWord(Address: Cardinal): Word;
    procedure WriteMemoryWord(Address: Cardinal; Value: Word);
    function ReadMemory(Address: Cardinal): Byte;
    procedure WriteMemory(Address: Cardinal; Value: Byte);
    procedure SetInput(const Input: TEmulatorInput);
    procedure InsertCoin(Player: Integer);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
    function PeripheralDebug: string;
    property CD: TS32CD read FCD;
    property Drive: TS32DriveBoard read FDrive;
    property SubBoard: TS32Console read FSubBoard;
    property FrameWidth: Integer read FFrameWidth;
    property FramePixels: TArray<TAlphaColor> read FFramePixels;
    property AudioSamples: TArray<SmallInt> read FAudioSamples;
    property Clock: Int64 read FTime;
    property Video: TS32Video read FVideo;
    property Sound: TS32Sound read FSound;
    property CPU: TV60 read FCPU;
    property FrameNumber: Int64 read FFrame;
  end;

implementation

uses
  Core.Emulation.Types, System.Classes, System.Math;

function Pad(const Input: TEmulatorInput; Index: Integer): TEmulatorButtons;
begin
  case Index of
    0:
      Result := Input.Buttons;
    1:
      Result := Input.Buttons2;
    2:
      Result := Input.Buttons3;
    3:
      Result := Input.Buttons4;
  else
    Result := [];
  end;
end;

constructor TS32Console.Create(Cart: TS32Cartridge; BoardIndex: Integer; Disc: TCDDisc);
begin
  inherited Create;
  FCart := Cart;
  FBoardIndex := BoardIndex;
  var Prefix := '';
  if BoardIndex <> 0 then
    Prefix := 'subpcb:';
  FROM := Cart[Prefix + 'maincpu'];
  FVideo := TS32Video.Create(Cart[Prefix + 'tiles'], Cart[Prefix + 'sprites']);
  FSound := TS32Sound.Create(Cart[Prefix + 'soundcpu']);
  FEEPROM := TSerialEEPROM93Cxx.Create;
  FEEPROM.ConfigureICT93C46A; // motherboard IC76: ICT 93C46AP
  // Self-timed EEPROM programming is not instantaneous. These durations
  // match the reference's estimates, not measurements of the ICT 93C46AP.
  FEEPROM.ConfigureTiming(16107950, 1750, 1000, 8000);
  if Cart.RomSet.Name.StartsWith('ga2') or Cart.RomSet.Name.StartsWith('arabfgt') then
    FProtection := TS32V25Protection.Create(Cart['mcu'], Cart.RomSet.Name.StartsWith('arabfgt'));
  FInterrupts := TS32Interrupts.Create;
  FCPU := TV60.Create(ReadMemory, WriteMemory, IRQVector);
  FCPU.ReadWord := ReadMemoryWord;
  FCPU.WriteWord := WriteMemoryWord;
  FCPU.ClockCallback := AdvanceCPUClock;
  FCPU.CycleModel := vcmBusConstraints;
  var Kind := bpNone;
  var Name := Cart.RomSet.Name;
  if Name = 'sonic' then
    Kind := bpSonic;
  if Name.StartsWith('brival') then
    Kind := bpBrival;
  if Name.StartsWith('darkedge') then
    Kind := bpDarkEdge;
  if Name = 'dbzvrvs' then
    Kind := bpDBZ;
  if (Name = 'f1lap') or (Name = 'f1lapj') then
    Kind := bpF1Lap;
  if Name.StartsWith('jleague') then
    Kind := bpJLeague;
  if (BoardIndex = 0) and Name.StartsWith('arescue') then
    Kind := bpAirRescue;
  FBusProtection := TS32BusProtection.Create(Kind, @FRAM, FROM);
  if Name.StartsWith('jpark') and (Length(Cart['cpu2']) <> 0) then
    FDrive := TS32DriveBoard.Create(Cart['cpu2']);
  SetLength(FLinkRAM, $1000);
  if (BoardIndex = 0) and (Length(Cart['subpcb:maincpu']) <> 0) then
  begin
    FSubBoard := TS32Console.Create(Cart, 1);
    FSubBoard.FLinkRAM := FLinkRAM;
  end;
  DIP[0] := $FF;
  DIP[1] := $FF;
  CDPrinterReady := True;
  if Name.StartsWith('kokoro') then
  begin
    FCD := TS32CD.Create(Disc);
    if Disc = nil then
      DIP[0] := $F7;
  end;
  Reset;
  var Data := Cart[Prefix + 'eeprom'];
  if Length(Data) = 128 then
  begin
    Data := Copy(Data);
    for var I := 0 to 63 do
    begin
      var T := Data[I * 2];
      Data[I * 2] := Data[I * 2 + 1];
      Data[I * 2 + 1] := T;
    end;
    FEEPROM.LoadBattery(Data);
  end;
end;

destructor TS32Console.Destroy;
begin
  FInterrupts.Free;
  FDrive.Free;
  FCD.Free;
  FSubBoard.Free;
  FBusProtection.Free;
  FCPU.Free;
  FEEPROM.Free;
  FSound.Free;
  FVideo.Free;
  FProtection.Free;
  inherited;
end;

procedure TS32Console.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FInterrupts.Reset;
  FillChar(FIO, SizeOf(FIO), 0);
  FillChar(FCoins, SizeOf(FCoins), 0);
  FillChar(FTrack, SizeOf(FTrack), 0);
  FGearHigh := False;
  FDirection := 0;
  FCount := 0;
  FTime := 0;
  FFrame := 0;
  SeedRandom($9BDF);
  FADCValue := $80;
  FSteeringValue := $80;
  FSteeringDigital := False;
  FSteeringRelative := False;
  FSteeringPhysicalValue := $80;
  FSteeringPhysicalValid := False;
  FADCBit := 0;
  FCPU.Reset;
  FVideo.Reset;
  FSound.Reset;
  FEEPROM.Reset;
  if FProtection <> nil then
    FProtection.Reset;
  FBusProtection.Reset;
  if FCD <> nil then
    FCD.Reset;
  if FDrive <> nil then
    FDrive.Reset;
  FillChar(FCXDData, SizeOf(FCXDData), 0);
  FillChar(FCXDDirection, SizeOf(FCXDDirection), $FF);
  FSpriteTime := -1;
  FFrameWidth := FVideo.Width;
  FFramePixels := Copy(FVideo.Pixels);
  FAudioSamples := nil;
  FillChar(FLinkRAM[0], Length(FLinkRAM), 0);
  if FSubBoard <> nil then
  begin
    FSubBoard.Reset;
    ComposeFrame;
  end;
end;

procedure TS32Console.UpdateIRQ;
begin
  FCPU.IRQLine := FInterrupts.IRQLine;
  if FInterrupts.SoundIRQ then
  begin
    FInterrupts.SoundIRQ := False;
    FSound.SignalIRQ(1);
  end;
end;

procedure TS32Console.SignalIRQ(Source: Integer);
begin
  FInterrupts.Signal(Source);
  UpdateIRQ;
end;

function TS32Console.IRQVector: Byte;
begin
  Result := FInterrupts.Vector;
end;

function TS32Console.Player(Index: Integer): Byte;
const
  Buttons: array[0..7] of TEmulatorButton = (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Down, TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Left);
begin
  Result := $FF;
  if FCart.RomSet.Inputs = 'sonic' then
  begin
    if TEmulatorButton.A in Pad(FInput, Index) then
      Result := Result and not 1;
    if (Index = 0) and (TEmulatorButton.A in FInput.Buttons3) then
      Result := Result and not 4;
    Exit;
  end;
  if FCart.RomSet.Inputs = 'darkedge' then
  begin
    Result := $FF;
    var B := Pad(FInput, Index);
    if TEmulatorButton.A in B then
      Result := Result and not 2;
    if TEmulatorButton.B in B then
      Result := Result and not 4;
    for var I := 4 to 7 do
      if Buttons[I] in B then
        Result := Result and not (1 shl I);
    Exit;
  end;
  if FCart.RomSet.Inputs = 'kokoroj2' then
  begin
    Result := $FF;
    for var P := 0 to 1 do
      for var B := 0 to 3 do
        if Buttons[B] in Pad(FInput, Index * 2 + P) then
          Result := Result and not (1 shl (P * 4 + B));
    Exit;
  end;
  if (FCart.RomSet.Inputs = 'radr') or (FCart.RomSet.Inputs = 'slipstrm') then
  begin
    Result := $FF;
    if (Index = 0) and FGearHigh then
      Result := Result and not 1;
    Exit;
  end;
  if FCart.RomSet.Inputs = 'radm' then
  begin
    if Index = 0 then
    begin
      if TEmulatorButton.X in FInput.Buttons then
        Result := Result and not 2;
      if TEmulatorButton.Y in FInput.Buttons then
        Result := Result and not 4;
    end;
    Exit;
  end;
  for var I := 0 to 7 do
    if Buttons[I] in Pad(FInput, Index) then
      Result := Result and not (1 shl I);
  Result := Result or 8; // generic connector D3 is not a fourth action button
  if FCart.RomSet.Inputs.StartsWith('spidman') or FCart.RomSet.Inputs.StartsWith('arabfgt') then
    Result := Result or $0C;
  if FCart.RomSet.Inputs.StartsWith('ga2') then
    Result := Result or 8;
  if FCart.RomSet.Inputs = 'brival' then
    Result := Result or 8;
  if (FCart.RomSet.Inputs = 'alien3') or (FCart.RomSet.Inputs = 'arescue') then
    if Index = 0 then
      Result := Result or $FC
    else if FCart.RomSet.Inputs = 'alien3' then
      Result := Result or $FC
    else
      Result := $FF;
  if FCart.RomSet.Inputs = 'jpark' then
    Result := Result or $FE;
  if (FCart.RomSet.Inputs = 'f1en') or (FCart.RomSet.Inputs = 'f1lap') then
    if Index = 0 then
      if FCart.RomSet.Inputs = 'f1en' then
        Result := Result or $FC
      else
        Result := Result or $F8
    else
      Result := $FF;
end;

function TS32Console.IORead(Index: Integer): Byte;
begin
  Index := Index and 15;
  if Index < 8 then
  begin
    if FDirection and (1 shl Index) <> 0 then
      Exit(FIO[Index]);
    case Index of
      0, 1:
        Exit(Player(Index));
      2:
        if FDrive <> nil then
          Exit($F0 or FDrive.Reply);
      4:
        begin
          Result := $FF;
          for var P := 0 to 1 do
          begin
            var CoinPort := P;
            if (FCart.RomSet.Inputs = 'spidmanu') or (FCart.RomSet.Inputs = 'arabfgtu') or (FCart.RomSet.Inputs = 'ga2u') then
              CoinPort := 3 - P;
            if FCart.RomSet.Inputs = 'alien3' then
              CoinPort := 1 - P;
            if FCoins[CoinPort] > 0 then
              Result := Result and not (4 shl P);
            var StartWired := (FCart.RomSet.Inputs <> 'alien3') and (FCart.RomSet.Inputs <> 'arescue');
            if P = 1 then
              StartWired := StartWired and (FCart.RomSet.Inputs <> 'radm') and
                (FCart.RomSet.Inputs <> 'radr') and (FCart.RomSet.Inputs <> 'slipstrm') and
                (FCart.RomSet.Inputs <> 'f1en') and (FCart.RomSet.Inputs <> 'f1lap');
            if StartWired and (TEmulatorButton.Start in Pad(FInput, P)) then
              Result := Result and not ($10 shl P);
          end;
          if TEmulatorButton.Mode in FInput.Buttons then
            Result := Result and not 2;
          if FCart.RomSet.Inputs = 'kokoroj2' then
          begin
            if TEmulatorButton.Start in FInput.Buttons3 then
              Result := Result and not $40;
            if TEmulatorButton.Start in FInput.Buttons4 then
              Result := Result and not $80;
          end;
          if FCart.RomSet.Inputs = 'sonic' then
          begin
            if FCoins[2] > 0 then
              Result := Result and not $40;
            if TEmulatorButton.Start in FInput.Buttons3 then
              Result := Result and not $80;
          end;
          Exit;
        end;
      5:
        begin
          Result := $70 or (DIP[0] and 15) or (Ord(FEEPROM.Output) shl 7);
          Exit;
        end;
    end;
    Exit($FF);
  end;
  case Index of
    8:
      Result := Ord('S');
    9:
      Result := Ord('E');
    10:
      Result := Ord('G');
    11:
      Result := Ord('A');
    12, 14:
      Result := FCount;
    13, 15:
      Result := FDirection;
  else
    Result := $FF;
  end;
end;

procedure TS32Console.Output(Index: Integer; Value: Byte);
begin
  case Index of
    3:
      FEEPROM.Lines(Value and $20 <> 0, Value and $40 <> 0, Value and $80 <> 0);
    6:
      if FDrive <> nil then
        FDrive.Command := Value;
    7:
      FVideo.TileBank := Value;
  end;
end;

procedure TS32Console.IOWrite(Index: Integer; Value: Byte);
begin
  Index := Index and 15;
  if Index < 8 then
  begin
    FIO[Index] := Value;
    if FDirection and (1 shl Index) <> 0 then
      Output(Index, Value);
  end
  else if Index = 14 then
  begin
    FCount := Value;
    FVideo.Enabled := Value and 2 <> 0;
    FSound.ResetLine := Value and 4 = 0;
  end
  else if Index = 15 then
  begin
    var Changed := FDirection xor Value;
    FDirection := Value;
    for var I := 0 to 7 do
      if Changed and (1 shl I) <> 0 then
        if Value and (1 shl I) <> 0 then
          Output(I, FIO[I])
        else
          Output(I, 0);
  end;
end;

function TS32Console.ReadMemoryWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFF;
  if (Address >= $D80000) and (Address < $E00000) and (Address and 1 = 0) then
    Exit(NextRandom);
  if FBusProtection.ReadWord(Address, Result) then
    Exit;
  Result := Word(ReadMemory(Address)) or (Word(ReadMemory(Address + 1)) shl 8);
end;

procedure TS32Console.WriteMemoryWord(Address: Cardinal; Value: Word);
begin
  Address := Address and $FFFFFF;
  if (Address >= $D80000) and (Address < $E00000) and (Address and 1 = 0) then
  begin
    SeedRandom(Value);
    Exit;
  end;
  if FBusProtection.Write(Address, Value, $FFFF) then
    Exit;
  if Address shr 20 = 2 then
  begin
    var Offset := Address and $FFFF;
    FRAM[Offset] := Byte(Value);
    FRAM[(Offset + 1) and $FFFF] := Byte(Value shr 8);
    FBusProtection.WorkRAMWritten(Offset);
  end
  else
  begin
    WriteMemory(Address, Byte(Value));
    WriteMemory(Address + 1, Byte(Value shr 8));
  end;
end;

function TS32Console.NextRandom: Word;
begin
  // Deterministic substitute: the real generator's clock/polynomial have
  // not been measured. Preserve its 16-bit bus width and seed interface.
  FRandom := FRandom xor (FRandom shl 13);
  FRandom := FRandom xor (FRandom shr 17);
  FRandom := FRandom xor (FRandom shl 5);
  Result := Word(FRandom);
end;

procedure TS32Console.SeedRandom(Value: Word);
begin
  FRandomSeed := Value;
  FRandom := $13570000 or Value;
end;

function TS32Console.ReadMemory(Address: Cardinal): Byte;
begin
  Address := Address and $FFFFFF;
  Result := $FF;
  if FBusProtection.ReadByte(Address, Result) then
    Exit;
  case Address shr 20 of
    0, 1:
      if Address < Cardinal(Length(FROM)) then
        Result := FROM[Address];
    2:
      Result := FRAM[Address and $FFFF];
    3:
      Result := FVideo.RAM[Address and $1FFFF];
    4:
      Result := FVideo.SpriteRAM[Address and $1FFFF];
    5:
      if Address and 1 = 0 then
        Result := FVideo.ReadControl((Address shr 1) and 7);
    6:
      if Address and $10000 = 0 then
        Result := FVideo.ReadPalette(Address)
      else
        Result := Byte(FVideo.Mixer[(Address shr 1) and $3F] shr (8 * (Address and 1)));
    7:
      Result := FSound.Shared[Address and $1FFF];
    8:
      if (Address >= $810000) and (Address < $811000) then
        Result := FLinkRAM[Address and $FFF]
      else if (Address >= $818000) and (Address < $818004) then
        if Address and 1 = 0 then
          Result := FBoardIndex
        else
          Result := 0;
    10:
      if (FProtection <> nil) and (Address < $A80000) and (Address and 1 = 0) then
        Result := FProtection.Shared[(Address shr 1) and $7FF];
    12:
      if Address and 1 = 0 then
      begin
        var Off := Address and $7F;
        if Off < $20 then
          Result := IORead(Off shr 1)
        else if (FCD <> nil) and (Off >= $40) and (Off < $60) then
          Result := FCD.Read((Off - $40) shr 1)
        else if (FCD <> nil) and (Off >= $60) and (Off < $70) then
        begin
          var Port := (Off - $60) shr 1;
          Result := 0;
          if Port < 5 then
          begin
            Result := FCXDData[Port] and not FCXDDirection[Port];
            // Disconnected printer inputs pull high. The optional virtual
            // ready line permits CD playback without a physical paper unit.
            if Port = 3 then
            begin
              var Pins: Byte := $FF;
              if CDPrinterReady then
                Pins := $FD;
              Result := Result or (FCXDDirection[Port] and Pins);
              FCXDReadPC := FCPU.GetRegister(32);
            end;
          end;
        end
        else if (FCart.RomSet.Inputs = 'sonic') and (Off >= $40) and (Off < $58) then
        begin
          var P := (Off - $40) div 8;
          var Axis := ((Off - $40) shr 2) and 1;
          Result := Byte((FTrack[P, Axis] and $FFF) shr (8 * ((Off shr 1) and 1)));
        end
        else if (Off >= $60) and (Off < $68) then
          case (Off shr 1) and 3 of
            0:
              if (FCart.RomSet.Inputs = 'brival') or (FCart.RomSet.Inputs = 'darkedge') then
                Result := $FF
              else
                Result := Player(2);
            1:
              if (FCart.RomSet.Inputs = 'brival') or (FCart.RomSet.Inputs = 'darkedge') then
              begin
                Result := $FF;
                var Buttons: TArray<TEmulatorButton> := [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z];
                if FCart.RomSet.Inputs = 'darkedge' then
                  Buttons := [TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y];
                for var I := 0 to 2 do
                begin
                  if Buttons[I] in FInput.Buttons2 then
                    Result := Result and not (1 shl I);
                  var Bit := 5;
                  if I = 1 then
                    Bit := 4
                  else if I = 2 then
                    Bit := 7;
                  if Buttons[I] in FInput.Buttons then
                    Result := Result and not (1 shl Bit);
                end;
              end
              else
                Result := Player(3);
            2:
              begin
                Result := $FF;
                if TEmulatorButton.Start in FInput.Buttons3 then
                  Result := Result and not 1;
                if TEmulatorButton.Start in FInput.Buttons4 then
                  Result := Result and not 2;
                if (FCart.RomSet.Inputs = 'spidmanu') or (FCart.RomSet.Inputs = 'arabfgtu') or (FCart.RomSet.Inputs = 'ga2u') then
                begin
                  if FCoins[1] > 0 then
                    Result := Result and not 4;
                  if FCoins[0] > 0 then
                    Result := Result and not 8;
                end;
              end;
            3:
              Result := $9B;
          end
        else if (Off >= $50) and (Off < $58) then
        begin
          Result := (FADCValue and $80) or $7F;
          FADCValue := Byte(FADCValue shl 1);
          Inc(FADCBit);
        end;
      end;
    13:
      if Address and $80000 = 0 then
      begin
        Result := FInterrupts.Read(Address and 15);
        UpdateIRQ;
      end
      else
      begin
        Result := Byte(NextRandom shr (8 * (Address and 1)));
      end;
    15:
      if (Address and $FFFFF) < Cardinal(Length(FROM)) then
        Result := FROM[Address and $FFFFF];
  end;
end;

procedure TS32Console.WriteMemory(Address: Cardinal; Value: Byte);
begin
  Address := Address and $FFFFFF;
  if FBusProtection.Write(Address and $FFFFFE, Word(Value) shl (8 * (Address and 1)), Word($FF) shl (8 * (Address and 1))) then
    Exit;
  case Address shr 20 of
    2:
      begin
        var Offset := Address and $FFFF;
        FRAM[Offset] := Value;
        FBusProtection.WorkRAMWritten(Offset);
      end;
    3:
      FVideo.RAM[Address and $1FFFF] := Value;
    4:
      FVideo.SpriteRAM[Address and $1FFFF] := Value;
    5:
      if Address and 1 = 0 then
        FVideo.Control[(Address shr 1) and 7] := Value;
    6:
      if Address and $10000 = 0 then
        FVideo.WritePalette(Address, Value)
      else
      begin
        var I := (Address shr 1) and $3F;
        var Shift := 8 * (Address and 1);
        FVideo.Mixer[I] := (FVideo.Mixer[I] and not (Word($FF) shl Shift)) or (Word(Value) shl Shift);
      end;
    7:
      FSound.Shared[Address and $1FFF] := Value;
    8:
      if (Address >= $810000) and (Address < $811000) then
        FLinkRAM[Address and $FFF] := Value;
    10:
      if (FProtection <> nil) and (Address < $A80000) and (Address and 1 = 0) then
        FProtection.Shared[(Address shr 1) and $7FF] := Value;
    12:
      if Address and 1 = 0 then
      begin
        var Off := Address and $7F;
        if Off < $20 then
          IOWrite(Off shr 1, Value)
        else if (FCD <> nil) and (Off >= $40) and (Off < $60) then
          FCD.Write((Off - $40) shr 1, Value)
        else if (FCD <> nil) and (Off >= $60) and (Off < $70) then
        begin
          var Port := (Off - $60) shr 1;
          if Port < 5 then
          begin
            FCXDData[Port] := Value;
            if Port = 4 then
              FCXDData[Port] := Value and 15;
          end
          else if Port = 6 then
            for var P := 0 to 3 do
              FCXDDirection[P] := ($0F * Ord(Value and (1 shl (P * 2)) <> 0)) or ($F0 * Ord(Value and (2 shl (P * 2)) <> 0))
          else if Port = 7 then
            FCXDDirection[4] := (Value and 15) or $F0;
        end
        else if (FCart.RomSet.Inputs = 'sonic') and (Off >= $40) and (Off < $58) then
        begin
          var P := (Off - $40) div 8;
          FTrack[P, 0] := 0;
          FTrack[P, 1] := 0;
        end
        else if (Off >= $50) and (Off < $58) then
        begin
          FADCValue := $80;
          var P := FInput.Buttons;
          case (Off shr 1) and 3 of
            0:
              begin
                FADCValue := AnalogAxisValue(0, False);
              end;
            1:
              begin
                FADCValue := 0;
                if FInput.Analog[0].Valid then
                  FADCValue := FInput.Analog[0].RightTrigger;
                FADCValue := Max(FADCValue, Round(255 * FInput.ButtonAmount(0, TEmulatorButton.A)));
              end;
            2:
              begin
                FADCValue := 0;
                if FInput.Analog[0].Valid then
                  FADCValue := FInput.Analog[0].LeftTrigger;
                FADCValue := Max(FADCValue, Round(255 * FInput.ButtonAmount(0, TEmulatorButton.B)));
              end;
          end;
          if UsesSteeringWheel and ((FCart.RomSet.Inputs = 'radm') or FSteeringRelative) and
            ((Off shr 1) and 3 = 0) then
            FADCValue := FSteeringValue;
          if (FCart.RomSet.Inputs = 'alien3') or (FCart.RomSet.Inputs = 'jpark') or (FCart.RomSet.Inputs = 'arescue') then
          begin
            var Axis := (Off shr 1) and 3;
            var PIndex := Axis div 2;
            if FCart.RomSet.Inputs = 'arescue' then
              PIndex := 0;
            var Analog := FInput.Analog[PIndex];
            FADCValue := AnalogAxisValue(PIndex, Axis and 1 <> 0);
          end;
          if FCart.RomSet.Inputs = 'arescue' then
          begin
            case (Off shr 1) and 3 of
              0:
                FADCValue := $FF - FADCValue;
              2:
                begin
                  FADCValue := $80;
                  if FInput.Analog[0].Valid then
                    FADCValue := EnsureRange(128 + (Integer(FInput.Analog[0].RightTrigger) - FInput.Analog[0].LeftTrigger) div 2, 0, 255);
                end;
            end;
          end;
          if (FCart.RomSet.Inputs = 'f1en') or (FCart.RomSet.Inputs = 'f1lap') or
            (FCart.RomSet.Inputs = 'radr') or (FCart.RomSet.Inputs = 'slipstrm') then
          begin
            case (Off shr 1) and 3 of
              1:
                begin
                  FADCValue := 0;
                  if FInput.Analog[0].Valid then
                    FADCValue := FInput.Analog[0].RightTrigger;
                  FADCValue := Max(FADCValue, Round(255 * FInput.ButtonAmount(0, TEmulatorButton.C)));
                end;
              2:
                begin
                  FADCValue := 0;
                  if FInput.Analog[0].Valid then
                    FADCValue := FInput.Analog[0].LeftTrigger;
                  FADCValue := Max(FADCValue, Round(255 * FInput.ButtonAmount(0, TEmulatorButton.X)));
                end;
            end;
          end;
          if (FCart.RomSet.Inputs = 'alien3') and ((Off shr 1) and 1 <> 0) then
            FADCValue := Max(1, FADCValue);
          if FCart.RomSet.Inputs = 'dbzvrvs' then
            FADCValue := $FF; // unconnected sensor ADC inputs
          FADCBit := 0;
        end;
      end;
    13:
      if Address and $80000 = 0 then
      begin
        FInterrupts.Write(Address and 15, Value);
        UpdateIRQ;
      end
      else
      begin
        var Shift := 8 * (Address and 1);
        SeedRandom((FRandomSeed and not (Word($FF) shl Shift)) or (Word(Value) shl Shift));
      end;
  end;
end;

procedure TS32Console.SetInput(const Input: TEmulatorInput);
begin
  if (FCart.RomSet.Inputs = 'radr') or (FCart.RomSet.Inputs = 'slipstrm') then
    if (TEmulatorButton.A in Input.Buttons) and not (TEmulatorButton.A in FInput.Buttons) then
      FGearHigh := not FGearHigh;
  for var I := 0 to 3 do
    if (TEmulatorButton.Select in Pad(Input, I)) and not (TEmulatorButton.Select in Pad(FInput, I)) then
      InsertCoin(I + 1);
  FInput := Input;
  if FSubBoard <> nil then
  begin
    var SubInput := Input;
    SubInput.Buttons := Input.Buttons2;
    SubInput.Buttons2 := [];
    SubInput.Analog[0] := Input.Analog[1];
    SubInput.AnalogButtons[0] := Input.AnalogButtons[1];
    SubInput.RelativeButtons[0] := Input.RelativeButtons[1];
    FSubBoard.SetInput(SubInput);
  end;
end;

procedure TS32Console.InsertCoin(Player: Integer);
begin
  if (FSubBoard <> nil) and (Player = 2) then
    FSubBoard.InsertCoin(1)
  else if (Player >= 1) and (Player <= 4) then
  begin
    var FourSlots := (FCart.RomSet.Inputs = 'spidmanu') or (FCart.RomSet.Inputs = 'arabfgtu') or (FCart.RomSet.Inputs = 'ga2u');
    if (Player > 2) and (FCart.RomSet.Inputs <> 'sonic') and not FourSlots then
      Player := 1 + ((Player - 1) and 1);
    FCoins[Player - 1] := 3;
  end;
end;

function TS32Console.UsesSteeringWheel: Boolean;
begin
  Result := (FCart.RomSet.Inputs = 'radm') or (FCart.RomSet.Inputs = 'radr') or
    (FCart.RomSet.Inputs = 'f1en') or (FCart.RomSet.Inputs = 'f1lap') or
    (FCart.RomSet.Inputs = 'slipstrm');
end;

function TS32Console.AnalogAxisValue(PlayerIndex: Integer; Vertical: Boolean): Byte;
begin
  var Negative := TEmulatorButton.Left;
  var Positive := TEmulatorButton.Right;
  if Vertical then
  begin
    Negative := TEmulatorButton.Up;
    Positive := TEmulatorButton.Down;
  end;
  var Digital := FInput.DigitalButton(PlayerIndex, Negative) or FInput.DigitalButton(PlayerIndex, Positive);
  if FInput.Analog[PlayerIndex].Valid and not Digital then
  begin
    var V := FInput.Analog[PlayerIndex].X;
    if Vertical then
      V := FInput.Analog[PlayerIndex].Y;
    Exit(EnsureRange(128 + V div 256, 0, 255));
  end;
  Result := EnsureRange(128 + Round(96 * (FInput.ButtonAmount(PlayerIndex, Positive) -
      FInput.ButtonAmount(PlayerIndex, Negative))), 0, 255);
end;

procedure TS32Console.BeginFrame;
begin
  if UsesSteeringWheel then
  begin
    var Left := TEmulatorButton.Left in FInput.RelativeButtons[0];
    var Right := TEmulatorButton.Right in FInput.RelativeButtons[0];
    if Left or Right then
    begin
      // One persistent angle: each emulated frame turns it by two ADC units.
      // Button release does not change the angle; opposing commands cancel.
      FSteeringRelative := True;
      FSteeringDigital := False;
      FSteeringValue := EnsureRange(Integer(FSteeringValue) + 2 * (Ord(Right) - Ord(Left)),
        Min($20, Integer(FSteeringValue)), Max($E0, Integer(FSteeringValue)));
    end
    else
    begin
      var Target := AnalogAxisValue(0, False);
      var Metadata := FInput.AnalogButtons[0];
      var Digital := FInput.DigitalButton(0, TEmulatorButton.Left) or
        FInput.DigitalButton(0, TEmulatorButton.Right);
      var Physical := FInput.Analog[0].Valid or (TEmulatorButton.Left in Metadata.Axes) or
        (TEmulatorButton.Right in Metadata.Axes);
      // An idle connected axis must not erase a keyboard-set angle. An actual
      // axis change or real device button immediately selects absolute input.
      var AbsoluteChanged := Digital or (Physical and
        ((FSteeringPhysicalValid and (Target <> FSteeringPhysicalValue)) or
        (not FSteeringPhysicalValid and (Target <> $80))));
      if FSteeringRelative and not AbsoluteChanged then
      begin
        if FInput.SteeringAutoCenter then
          FSteeringValue := EnsureRange(128, Max(0, Integer(FSteeringValue) - 2),
            Min(255, Integer(FSteeringValue) + 2));
      end
      else
      begin
        FSteeringRelative := False;
        if (FCart.RomSet.Inputs <> 'radm') or
          (Physical and not Digital and not FSteeringDigital) then
          FSteeringValue := Target // preserve direct absolute input for each board
        else
        begin
          // Preserve the existing real-button path and ROM sample protection.
          var Step := 31;
          if Metadata.Valid = [] then
            Step := 10;
          FSteeringValue := EnsureRange(Integer(Target), Max(0, Integer(FSteeringValue) - Step),
            Min(255, Integer(FSteeringValue) + Step));
        end;
        FSteeringDigital := Digital or (FSteeringDigital and (FSteeringValue <> Target));
      end;
      FSteeringPhysicalValue := Target;
      FSteeringPhysicalValid := Physical;
    end;
  end;
  FSound.BeginFrame;
  FVideo.BeginFrame;
  if FCart.RomSet.Inputs = 'sonic' then
    for var P := 0 to 2 do
    begin
      var B := Pad(FInput, P);
      var DX := 0;
      var DY := 0;
      if FInput.Analog[P].Valid then
      begin
        DX := FInput.Analog[P].X div 1100;
        DY := FInput.Analog[P].Y div 1100;
      end;
      if not FInput.Analog[P].Valid or FInput.DigitalButton(P, TEmulatorButton.Left) or
        FInput.DigitalButton(P, TEmulatorButton.Right) then
        DX := Round(30 * (FInput.ButtonAmount(P, TEmulatorButton.Right) - FInput.ButtonAmount(P, TEmulatorButton.Left)));
      if not FInput.Analog[P].Valid or FInput.DigitalButton(P, TEmulatorButton.Up) or
        FInput.DigitalButton(P, TEmulatorButton.Down) then
        DY := Round(30 * (FInput.ButtonAmount(P, TEmulatorButton.Down) - FInput.ButtonAmount(P, TEmulatorButton.Up)));
      FTrack[P, 0] := Word((Integer(FTrack[P, 0]) - DX) and $FFF);
      FTrack[P, 1] := Word((Integer(FTrack[P, 1]) + DY) and $FFF);
    end;
  SignalIRQ(1);
  FSpriteTime := (FFrame * 16107950 div 60) + (16107950 * Int64(50) + 999999) div 1000000;
  Inc(FFrame);
end;

procedure TS32Console.AdvanceCPUClock(Cycles: Integer);
begin
  var Target := FTime + Cycles;
  while FTime < Target do
  begin
    var Next := Min(Target, FInterrupts.NextEvent);
    if FSpriteTime >= 0 then
      Next := Min(Next, FSpriteTime);
    if Next > FTime then
      FTime := Next;
    FEEPROM.RunUntil(FTime);
    FInterrupts.RunUntil(FTime);
    UpdateIRQ;
    FSound.RunUntil(FTime div 2);
    if FCD <> nil then
      FCD.RunUntil(FTime);
    if FDrive <> nil then
      FDrive.RunUntil(FTime);
    if FProtection <> nil then
      FProtection.RunUntil(FTime * 10000000 div 16107950);
    if FSound.MainIRQ then
    begin
      FSound.MainIRQ := False;
      SignalIRQ(2);
    end;
    FInterrupts.RunUntil(FTime);
    UpdateIRQ;
    if (FSpriteTime >= 0) and (FTime >= FSpriteTime) then
    begin
      FSpriteTime := -1;
      FVideo.UpdateSprites;
    end;
  end;
end;

procedure TS32Console.RunUntil(Target: Int64);
begin
  while FTime < Target do
    FCPU.Run(Integer(Min(Int64(64), Target - FTime)));
end;

procedure TS32Console.EndFrame;
begin
  FSound.EndFrame;
  if FCD <> nil then
    FCD.Mix(FSound.Samples);
  if FCart.RomSet.Inputs = 'holo' then
    for var Y := 0 to 111 do
      for var X := 0 to FVideo.Width - 1 do
      begin
        var A := Y * FVideo.Width + X;
        var B := (223 - Y) * FVideo.Width + X;
        var Pixel := FVideo.Pixels[A];
        FVideo.Pixels[A] := FVideo.Pixels[B];
        FVideo.Pixels[B] := Pixel;
      end;
  for var I := 0 to 3 do
    if FCoins[I] > 0 then
      Dec(FCoins[I]);
end;

procedure TS32Console.ComposeFrame;
begin
  FFrameWidth := FVideo.Width;
  if FSubBoard = nil then
  begin
    FFramePixels := Copy(FVideo.Pixels);
    FAudioSamples := Copy(FSound.Samples);
    Exit;
  end;
  Inc(FFrameWidth, FSubBoard.Video.Width);
  SetLength(FFramePixels, FFrameWidth * 224);
  for var Y := 0 to 223 do
  begin
    Move(FVideo.Pixels[Y * FVideo.Width], FFramePixels[Y * FFrameWidth], FVideo.Width * 4);
    Move(FSubBoard.Video.Pixels[Y * FSubBoard.Video.Width], FFramePixels[Y * FFrameWidth + FVideo.Width], FSubBoard.Video.Width * 4);
  end;
  SetLength(FAudioSamples, Length(FSound.Samples));
  for var I := 0 to High(FAudioSamples) do
  begin
    var V := Integer(FSound.Samples[I]);
    if I < Length(FSubBoard.Sound.Samples) then
      Inc(V, FSubBoard.Sound.Samples[I]);
    FAudioSamples[I] := V div 2;
  end;
end;

procedure TS32Console.RunFrame;
begin
  BeginFrame;
  if FSubBoard <> nil then
  begin
    FSubBoard.DIP[0] := DIP[1];
    FSubBoard.BeginFrame;
  end;
  for var Line := 0 to 261 do
  begin
    if Line = 224 then
    begin
      SignalIRQ(0);
      FBusProtection.VBlank;
      if FSubBoard <> nil then
      begin
        FSubBoard.SignalIRQ(0);
        FSubBoard.FBusProtection.VBlank;
      end;
    end;
    var Target := ((FFrame - 1) * 262 + Line + 1) * 16107950 div (60 * 262);
    // Interleave both complete boards on the same clock, with no frame-sized lag.
    while FTime < Target do
    begin
      var Quantum := 64;
      if FSubBoard <> nil then
        Quantum := 8;
      var Next := Min(Target, FTime + Quantum);
      RunUntil(Next);
      if FSubBoard <> nil then
        FSubBoard.RunUntil(Next);
    end;
    if Line < 224 then
    begin
      FVideo.RenderLine(Line);
      if FSubBoard <> nil then
        FSubBoard.Video.RenderLine(Line);
    end;
  end;
  EndFrame;
  if FSubBoard <> nil then
    FSubBoard.EndFrame;
  ComposeFrame;
end;

function TS32Console.Battery: TBytes;
begin
  Result := FEEPROM.Battery;
  if FSubBoard <> nil then
    Result := Result + FSubBoard.FEEPROM.Battery;
  // Preserve the complete legacy EEPROM prefix, also for two-PCB cabinets.
  // Older readers can still load it; new readers append each PCB's 8 KiB
  // battery-backed sound/shared SRAM in physical-board order.
  var EEPROMBytes := Length(Result);
  var Boards := 1 + Ord(FSubBoard <> nil);
  SetLength(Result, EEPROMBytes + Boards * SizeOf(FSound.Shared));
  Move(FSound.Shared, Result[EEPROMBytes], SizeOf(FSound.Shared));
  if FSubBoard <> nil then
    Move(FSubBoard.FSound.Shared, Result[EEPROMBytes + SizeOf(FSound.Shared)], SizeOf(FSound.Shared));
end;

function TS32Console.PeripheralDebug: string;
begin
  Result := Format('CXD poll=%.8x data=%.2x %.2x %.2x %.2x %.2x dir=%.2x %.2x %.2x %.2x %.2x',
    [FCXDReadPC, FCXDData[0], FCXDData[1], FCXDData[2], FCXDData[3], FCXDData[4], FCXDDirection[0], FCXDDirection[1], FCXDDirection[2], FCXDDirection[3], FCXDDirection[4]]);
  if FDrive <> nil then
    Result := Result + Format(' drive pc=%.4x command=%.2x reply=%.1x', [FDrive.CPU.ProgramCounter, FDrive.Command, FDrive.Reply]);
end;

procedure TS32Console.LoadBattery(const Data: TBytes);
begin
  FEEPROM.LoadBattery(Copy(Data, 0, 128));
  if (FSubBoard <> nil) and (Length(Data) >= 256) then
    FSubBoard.FEEPROM.LoadBattery(Copy(Data, 128, 128));
  var Boards := 1 + Ord(FSubBoard <> nil);
  var EEPROMBytes := 128 * Boards;
  if Length(Data) = EEPROMBytes + Boards * SizeOf(FSound.Shared) then
  begin
    Move(Data[EEPROMBytes], FSound.Shared, SizeOf(FSound.Shared));
    if FSubBoard <> nil then
      Move(Data[EEPROMBytes + SizeOf(FSound.Shared)], FSubBoard.FSound.Shared, SizeOf(FSound.Shared));
  end;
end;

procedure TS32Console.SerializeState(State: TStateArchive);
begin
  FCPU.SerializeState(State);
  FVideo.SerializeState(State);
  FSound.SerializeState(State);
  FEEPROM.SerializeState(State);
  if FProtection <> nil then
    FProtection.SerializeState(State);
  FBusProtection.SerializeState(State);
  if FCD <> nil then
    FCD.SerializeState(State);
  if FDrive <> nil then
    FDrive.SerializeState(State);
  State.Field(FCXDData, SizeOf(FCXDData));
  State.Field(FCXDDirection, SizeOf(FCXDDirection));
  State.Field(FSpriteTime, SizeOf(FSpriteTime));
  if FSubBoard <> nil then
  begin
    State.Field(FLinkRAM[0], Length(FLinkRAM));
    FSubBoard.SerializeState(State);
  end;
  State.Field(FRAM, SizeOf(FRAM));
  FInterrupts.SerializeState(State);
  State.Field(FIO, SizeOf(FIO));
  State.Field(FDirection, SizeOf(FDirection));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FFrame, SizeOf(FFrame));
  if State.Version = 8 then
  begin
    // Explicit v8 output remains useful for migration fixtures.
    if State.Loading then
      State.CompatibleField(FInput, SizeOf(FInput), TEmulatorInput.LegacySize, TEmulatorInput.TravelSize)
    else
      State.Field(FInput, TEmulatorInput.LegacySize);
  end
  else if (State.Version = 9) and not State.Loading then
    State.Field(FInput, TEmulatorInput.TravelSize)
  else
    State.CompatibleField(FInput, SizeOf(FInput), TEmulatorInput.LegacySize, TEmulatorInput.TravelSize);
  State.Field(FCoins, SizeOf(FCoins));
  State.Field(FRandom, SizeOf(FRandom));
  State.Field(FADCValue, SizeOf(FADCValue));
  State.Field(FADCBit, SizeOf(FADCBit));
  State.Field(FRandomSeed, SizeOf(FRandomSeed));
  State.Field(FTrack, SizeOf(FTrack));
  State.Field(DIP, SizeOf(DIP));
  State.Field(CDPrinterReady, SizeOf(CDPrinterReady));
  State.Field(FGearHigh, SizeOf(FGearHigh));
  if (State.Version = 0) or (State.Version >= 9) then
  begin
    State.Field(FSteeringValue, SizeOf(FSteeringValue));
    State.Field(FSteeringDigital, SizeOf(FSteeringDigital));
  end
  else if State.Loading then
  begin
    FSteeringValue := $80; // v8 had no moving host wheel state
    FSteeringDigital := False;
  end;
  if (State.Version = 0) or (State.Version >= 10) then
  begin
    State.Field(FSteeringRelative, SizeOf(FSteeringRelative));
    State.Field(FSteeringPhysicalValue, SizeOf(FSteeringPhysicalValue));
    State.Field(FSteeringPhysicalValid, SizeOf(FSteeringPhysicalValid));
  end
  else if State.Loading then
  begin
    FSteeringRelative := False;
    FSteeringPhysicalValue := $80;
    FSteeringPhysicalValid := False;
  end;
  if (FBoardIndex = 0) and (FSubBoard = nil) then
  begin
    // Twin cabinets already serialize shared comms RAM before the sub-board.
    if (State.Version = 0) or (State.Version >= 11) then
      State.Field(FLinkRAM[0], Length(FLinkRAM))
    else if State.Loading then
      FillChar(FLinkRAM[0], Length(FLinkRAM), 0);
  end;
  ComposeFrame;
  if (FFrame < 0) or (FTime < 0) then
    raise EReadError.Create('Invalid System 32 scheduler state');
end;

function TS32Console.ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;

  procedure Advance(Read: Cardinal);
  begin
    Inc(Address, Read);
    Inc(Buffer, Read);
    Dec(Count, Read);
    Inc(Result, Read);
  end;

  procedure ReadBlock(Base: Cardinal; Memory: PByte; Size: Cardinal; ByteXor: Cardinal = 0);
  begin
    if (Address < Base) or (Address - Base >= Size) or (Count = 0) then
      Exit;
    if Memory <> nil then
      Advance(ReadAchievementMemoryBlock(Address - Base, Buffer, Count, Memory, Size, ByteXor))
    else
    begin
      var Read := Min(Count, Size - (Address - Base));
      FillChar(Buffer^, Read, 0);
      Advance(Read);
    end;
  end;

begin
  Result := 0;
  if (Buffer = nil) or (Count = 0) then
    Exit;
  // FBNeo allocates both V60/V70 and palette banks in AllRam. The supported
  // V60 boards leave the upper work RAM and second palette slot zero-filled.
  ReadBlock($00000, @FRAM, SizeOf(FRAM));
  ReadBlock($10000, nil, $10000);
  ReadBlock($20000, @FVideo.Palette, SizeOf(FVideo.Palette));
  ReadBlock($28000, nil, $8000);
  ReadBlock($30000, @FVideo.RAM, SizeOf(FVideo.RAM));
  ReadBlock($50000, @FVideo.SpriteRAM, SizeOf(FVideo.SpriteRAM));
  ReadBlock($70000, @FVideo.SpriteRAM, SizeOf(FVideo.SpriteRAM), 3);
  ReadBlock($90000, @FSound.Shared, SizeOf(FSound.Shared));
  ReadBlock($92000, Pointer(FLinkRAM), Length(FLinkRAM));
  if (Address >= $93000) and (Count <> 0) then
  begin
    if FProtection <> nil then
      ReadBlock($93000, @FProtection.Shared, SizeOf(FProtection.Shared))
    else
      Advance(FBusProtection.ReadAchievementRAM(Address - $93000, Buffer, Count));
    ReadBlock($93000, nil, $10000);
  end;
end;

end.

