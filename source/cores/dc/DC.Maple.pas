unit DC.Maple;

// Maple bus: DMA command lists and the devices on ports A-D. The standard
// controller and its expansion devices (VMU, Puru Puru), the keyboard, mouse
// and light gun answer the frame protocol: device info, get/set condition,
// block read/write, reset.
// Reference: Marcus Comstedt, "Maple bus" and "Controller" pages.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, DC.Types,
  DC.Memory;

const
  MapleFuncController = $01000000;
  MapleFuncStorage = $02000000;
  MapleFuncLCD = $04000000;
  MapleFuncClock = $08000000;
  MapleFuncVibration = $00010000;
  MapleFuncMouse = $00020000;
  MapleFuncKeyboard = $40000000;
  MapleFuncLightGun = $80000000;

  // Mouse buttons (active low on the bus).
  MapleMouseRight = $0002;
  MapleMouseLeft = $0004;
  MapleMouseSide = $0008;

  // Controller buttons (active low on the bus).
  MapleC = $0001;
  MapleB = $0002;
  MapleA = $0004;
  MapleStart = $0008;
  MapleUp = $0010;
  MapleDown = $0020;
  MapleLeft = $0040;
  MapleRight = $0080;
  MapleZ = $0100;
  MapleY = $0200;
  MapleX = $0400;
  MapleD = $0800;

type
  TDCPad = record
    Buttons: Word;        // Maple* bits set when pressed
    StickX, StickY: Byte; // 0..255, 128 centred
    LeftTrigger, RightTrigger: Byte;
  end;

  TDCMapleDevice = class
  public
    // Handles one frame: the response code and its length in words.
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; virtual; abstract;
    procedure SerializeState(Archive: TStateArchive); virtual;
  end;

  TDCController = class(TDCMapleDevice)
  public
    Pad: TDCPad;
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; override;
  end;

  // Light gun: a controller (trigger on A, B, Start, D-pad) whose position
  // comes from the video counters latched when the Maple bus is put into
  // light gun mode for its port.
  TDCLightGun = class(TDCController)
  public
    // Aim in frame pixels; OnScreen False when pointing off the picture.
    X, Y: Integer;
    OnScreen: Boolean;
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; override;
  end;

  // Keyboard: up to six keys (USB HID usage codes) and the modifier bits.
  TDCKeyboard = class(TDCMapleDevice)
  public
    // 1 Japanese, 2 US, 3 UK, 4 German, 5 French, 6 Italian, 7 Spanish layout.
    Region: Byte;
    Modifiers, LEDs: Byte;
    Keys: array[0..5] of Byte;
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; override;
  end;

  // Mouse: buttons (MapleMouse* bits while pressed) and the movement since
  // the previous condition read.
  TDCMouse = class(TDCMapleDevice)
  public
    Buttons: Word;
    DX, DY, DZ: Integer;
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; override;
  end;

  // Visual Memory: 128 KiB flash (256 blocks of 512 bytes), the 48x32
  // monochrome LCD and the clock.
  TDCVMU = class(TDCMapleDevice)
  public
    Data: TBytes;
    LCD: array[0..191] of Byte;
    Dirty, LCDChanged: Boolean;
    constructor Create;
    procedure Format;
    function Handle(Command, Address: Byte; Data_: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; override;
    procedure SerializeState(Archive: TStateArchive); override;
  end;

  // Puru Puru (jump) pack: vibration settings from SETCOND.
  TDCPuruPuru = class(TDCMapleDevice)
  public
    Setting: Cardinal;
    function Level: Byte;
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer; override;
    procedure SerializeState(Archive: TStateArchive); override;
  end;

  TDCMaple = class
  private
    FMemory: TDCMemory;
    function DispatchFrame(Port: Integer; Frame: PCardinal; Words: Integer; Reply: PCardinal): Integer;
  public
    // [port, unit]: unit 0 is the main device, 1..5 its expansion sockets.
    Devices: array[0..3, 0..5] of TDCMapleDevice;
    // Optional diagnostics: one line per frame.
    Trace: TStrings;
    // Latches the video counters for a light gun aimed at frame pixel X, Y.
    OnLightGun: procedure(X, Y: Integer) of object;
    constructor Create(Memory: TDCMemory);
    destructor Destroy; override;
    procedure Attach(Port, AUnit: Integer; Device: TDCMapleDevice);
    // Runs a DMA command table at physical Table; returns the bus words moved.
    function RunDMA(Table: Cardinal): Integer;
    procedure SerializeState(Archive: TStateArchive);
  end;

// Fixed-size ASCII field, padded with spaces, packed into little-endian words.
procedure MapleText(Dest: PByte; const Text: AnsiString; Size: Integer);

implementation

procedure MapleText(Dest: PByte; const Text: AnsiString; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    if I < Length(Text) then
      Dest[I] := Ord(Text[I + 1])
    else
      Dest[I] := $20;
end;

{ TDCMapleDevice }

procedure TDCMapleDevice.SerializeState(Archive: TStateArchive);
begin
end;

{ TDCController }

function TDCController.Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer;
begin
  Response := $FD;
  Result := 0;
  case Command of
    1, 2:
      begin
        // Device info: function, three function data words, area, direction,
        // product name, license, standby and maximum power.
        FillChar(Reply^, 28 * 4, 0);
        Reply[0] := MapleFuncController;
        // Capabilities: A, B, X, Y, Start, D-pad, analog triggers and stick.
        Reply[1] := $FE060F00;
        var B := PByte(@Reply[4]);
        B[0] := $FF;
        B[1] := 0;
        MapleText(B + 2, 'Dreamcast Controller', 30);
        MapleText(B + 32, 'Produced By or Under License From SEGA ENTERPRISES,LTD.', 60);
        PWord(B + 92)^ := $01AE;
        PWord(B + 94)^ := $01F4;
        Response := 5;
        Exit(28);
      end;
    3:
      begin
        Response := 7;
        Exit(0);
      end;
    9:
      begin
        if (Words < 1) or (Data[0] <> MapleFuncController) then
        begin
          Response := $FE;
          Exit(0);
        end;
        Reply[0] := MapleFuncController;
        Reply[1] := (not Cardinal(Pad.Buttons) and $FFFF) or (Cardinal(Pad.RightTrigger) shl 16) or
          (Cardinal(Pad.LeftTrigger) shl 24);
        Reply[2] := Cardinal(Pad.StickX) or (Cardinal(Pad.StickY) shl 8) or (Cardinal($80) shl 16) or (Cardinal($80) shl 24);
        Response := 8;
        Exit(3);
      end;
  end;
end;

// Device info: functions, three function data words, area, direction, product
// name, license, standby and maximum power (0.1 mA).
function DeviceInfo(Reply: PCardinal; Functions, Data0, Data1: Cardinal; const Name: AnsiString; Standby, MaxPower: Word): Integer;
begin
  FillChar(Reply^, 28 * 4, 0);
  Reply[0] := Functions;
  Reply[1] := Data0;
  Reply[2] := Data1;
  var B := PByte(@Reply[4]);
  B[0] := $FF;
  B[1] := 0;
  MapleText(B + 2, Name, 30);
  MapleText(B + 32, 'Produced By or Under License From SEGA ENTERPRISES,LTD.', 60);
  PWord(B + 92)^ := Standby;
  PWord(B + 94)^ := MaxPower;
  Result := 28;
end;

{ TDCLightGun }

function TDCLightGun.Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer;
begin
  if Command in [1, 2] then
  begin
    // Function data in descending function order: light gun, controller.
    Response := 5;
    Exit(DeviceInfo(Reply, MapleFuncLightGun or MapleFuncController, 0, $FE060F00, 'Dreamcast Gun',
        $0069, $0120));
  end;
  Result := inherited Handle(Command, Address, Data, Words, Reply, Response);
end;

{ TDCKeyboard }

function TDCKeyboard.Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer;
begin
  Response := $FD;
  Result := 0;
  case Command of
    1, 2:
      begin
        // The function data's low byte gives the layout.
        Response := 5;
        Exit(DeviceInfo(Reply, MapleFuncKeyboard, Region, 0, 'Keyboard', $012C, $01F4));
      end;
    3:
      Response := 7;
    9:
      begin
        if (Words < 1) or (Data[0] <> MapleFuncKeyboard) then
        begin
          Response := $FE;
          Exit(0);
        end;
        Reply[0] := MapleFuncKeyboard;
        Reply[1] := Cardinal(Modifiers) or (Cardinal(LEDs) shl 8) or (Cardinal(Keys[0]) shl 16) or
          (Cardinal(Keys[1]) shl 24);
        Reply[2] := Cardinal(Keys[2]) or (Cardinal(Keys[3]) shl 8) or (Cardinal(Keys[4]) shl 16) or
          (Cardinal(Keys[5]) shl 24);
        Response := 8;
        Exit(3);
      end;
    14:
      begin
        // SETCOND: the LED state.
        if (Words >= 2) and (Data[0] = MapleFuncKeyboard) then
          LEDs := Byte(Data[1]);
        Response := 7;
      end;
  end;
end;

{ TDCMouse }

function TDCMouse.Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer;

  // Ten-bit axis centred on 200h; what does not fit stays for the next read.
  function Take(var Delta: Integer): Cardinal;
  begin
    var Part := EnsureRange(Delta, -$1FF, $1FF);
    Dec(Delta, Part);
    Result := Cardinal(Part + $200);
  end;

begin
  Response := $FD;
  Result := 0;
  case Command of
    1, 2:
      begin
        Response := 5;
        Exit(DeviceInfo(Reply, MapleFuncMouse, 0, 0, 'Dreamcast Mouse', $0069, $0120));
      end;
    3:
      Response := 7;
    9:
      begin
        if (Words < 1) or (Data[0] <> MapleFuncMouse) then
        begin
          Response := $FE;
          Exit(0);
        end;
        Reply[0] := MapleFuncMouse;
        Reply[1] := not Cardinal(Buttons) and $FFFF;
        Reply[2] := Take(DX) or (Take(DY) shl 16);
        Reply[3] := Take(DZ) or ($200 shl 16);
        Reply[4] := $02000200;
        Reply[5] := $02000200;
        Response := 8;
        Exit(6);
      end;
  end;
end;

{ TDCVMU }

constructor TDCVMU.Create;
begin
  inherited Create;
  SetLength(Data, 128 * 1024);
  Format;
  Dirty := False;
end;

procedure TDCVMU.Format;
begin
  // A blank card: root block 255, FAT 254, 13 directory blocks 253..241,
  // 200 user blocks.
  FillChar(Data[0], Length(Data), 0);
  var Root := 255 * 512;
  for var I := 0 to 15 do
    Data[Root + I] := $55;
  PWord(@Data[Root + $46])^ := 254;
  PWord(@Data[Root + $48])^ := 1;
  PWord(@Data[Root + $4A])^ := 253;
  PWord(@Data[Root + $4C])^ := 13;
  PWord(@Data[Root + $50])^ := 200;
  var FAT := 254 * 512;
  for var B := 0 to 255 do
    PWord(@Data[FAT + B * 2])^ := $FFFC;
  PWord(@Data[FAT + 255 * 2])^ := $FFFA;
  PWord(@Data[FAT + 254 * 2])^ := $FFFA;
  for var B := 242 to 253 do
    PWord(@Data[FAT + B * 2])^ := Word(B - 1);
  PWord(@Data[FAT + 241 * 2])^ := $FFFA;
  Dirty := True;
end;

function TDCVMU.Handle(Command, Address: Byte; Data_: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer;
begin
  Response := $FD;
  Result := 0;
  var Func: Cardinal := 0;
  if Words >= 1 then
    Func := Data_[0];
  case Command of
    1, 2:
      begin
        FillChar(Reply^, 28 * 4, 0);
        Reply[0] := MapleFuncStorage or MapleFuncLCD or MapleFuncClock;
        Reply[1] := $403F7E7E;
        Reply[2] := $00100500;
        Reply[3] := $00410F00;
        var B := PByte(@Reply[4]);
        B[0] := $FF;
        MapleText(B + 2, 'Visual Memory', 30);
        MapleText(B + 32, 'Produced By or Under License From SEGA ENTERPRISES,LTD.', 60);
        PWord(B + 92)^ := $007C;
        PWord(B + 94)^ := $0082;
        Response := 5;
        Exit(28);
      end;
    3:
      begin
        Response := 7;
        Exit(0);
      end;
    9:
      if Func = MapleFuncClock then
      begin
        // Date: year (big-endian 16 bit), month, day, hour, minute, second, weekday.
        Reply[0] := MapleFuncClock;
        Reply[1] := $01000AD0;
        Reply[2] := 0;
        Response := 8;
        Exit(3);
      end;
    10:
      if Func = MapleFuncStorage then
      begin
        // Media information: last block, partition, system/FAT/directory
        // locations and sizes, icon and a reserved byte, then the save area
        // (user blocks start at 200 and down, executable area of 31 blocks).
        FillChar(Reply^, 7 * 4, 0);
        Reply[0] := MapleFuncStorage;
        var W := PWord(@Reply[1]);
        W[0] := 255;
        W[1] := 0;
        W[2] := 255;
        W[3] := 254;
        W[4] := 1;
        W[5] := 253;
        W[6] := 13;
        W[7] := 0;
        W[8] := 200;
        W[9] := 31;
        Response := 8;
        Exit(7);
      end;
    11:
      if (Func = MapleFuncStorage) and (Words >= 2) then
      begin
        var Location := Data_[1];
        var Block := Integer(((Location shr 24) and $FF) or (((Location shr 16) and $FF) shl 8)) and 255;
        Reply[0] := MapleFuncStorage;
        Reply[1] := Location;
        Move(Data[Block * 512], Reply[2], 512);
        Response := 8;
        Exit(130);
      end;
    12:
      if (Func = MapleFuncStorage) and (Words >= 2) then
      begin
        var Location := Data_[1];
        var Block := Integer(((Location shr 24) and $FF) or (((Location shr 16) and $FF) shl 8)) and 255;
        var Phase := Integer((Location shr 8) and 3);
        var Count := (Words - 2) * 4;
        if Count > 128 then
          Count := 128;
        if Count > 0 then
          Move(Data_[2], Data[Block * 512 + Phase * 128], Count);
        Dirty := True;
        Response := 7;
        Exit(0);
      end
      else if (Func = MapleFuncLCD) and (Words >= 2) then
      begin
        var Count := (Words - 2) * 4;
        if Count > 192 then
          Count := 192;
        if Count > 0 then
          Move(Data_[2], LCD[0], Count);
        LCDChanged := True;
        Response := 7;
        Exit(0);
      end
      else if Func = MapleFuncClock then
      begin
        Response := 7;
        Exit(0);
      end;
    13, 14:
      begin
        Response := 7;
        Exit(0);
      end;
  end;
  if Command in [9..14] then
    Response := $FE;
end;

procedure TDCVMU.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(Data[0], Length(Data));
  Archive.Field(LCD, SizeOf(LCD));
  if Archive.Loading then
  begin
    Dirty := True;
    LCDChanged := True;
  end;
end;

{ TDCPuruPuru }

function TDCPuruPuru.Level: Byte;
begin
  // Effect intensity in bits 8..10 (power, 1..7).
  var Power := (Setting shr 8) and 7;
  Result := Byte(Power * 36);
end;

function TDCPuruPuru.Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal; out Response: Byte): Integer;
begin
  Response := $FD;
  Result := 0;
  case Command of
    1, 2:
      begin
        FillChar(Reply^, 28 * 4, 0);
        Reply[0] := MapleFuncVibration;
        Reply[1] := $01010000;
        var B := PByte(@Reply[4]);
        B[0] := $FF;
        MapleText(B + 2, 'Puru Puru Pack', 30);
        MapleText(B + 32, 'Produced By or Under License From SEGA ENTERPRISES,LTD.', 60);
        PWord(B + 92)^ := $00C8;
        PWord(B + 94)^ := $0640;
        Response := 5;
        Exit(28);
      end;
    3:
      begin
        Setting := 0;
        Response := 7;
        Exit(0);
      end;
    9:
      begin
        Reply[0] := MapleFuncVibration;
        Reply[1] := Setting;
        Response := 8;
        Exit(2);
      end;
    14:
      begin
        if Words >= 2 then
          Setting := Data[1];
        Response := 7;
        Exit(0);
      end;
  end;
end;

procedure TDCPuruPuru.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(Setting, SizeOf(Setting));
end;

{ TDCMaple }
constructor TDCMaple.Create(Memory: TDCMemory);
begin
  inherited Create;
  FMemory := Memory;
end;

destructor TDCMaple.Destroy;
begin
  for var P := 0 to 3 do
    for var U := 0 to 5 do
      Devices[P, U].Free;
  inherited;
end;

procedure TDCMaple.Attach(Port, AUnit: Integer; Device: TDCMapleDevice);
begin
  if Devices[Port, AUnit] <> Device then
    Devices[Port, AUnit].Free;
  Devices[Port, AUnit] := Device;
end;

function TDCMaple.DispatchFrame(Port: Integer; Frame: PCardinal; Words: Integer; Reply: PCardinal): Integer;
begin
  // Header: command, recipient, sender, length (words).
  var Header := Frame[0];
  var Command := Byte(Header);
  var Recipient := Byte(Header shr 8);
  var AUnit := 0;
  if (Recipient and $20) = 0 then
    for var Bit := 0 to 4 do
      if (Recipient and (1 shl Bit)) <> 0 then
      begin
        AUnit := Bit + 1;
        Break;
      end;
  var Device := Devices[Port, AUnit];
  if Trace <> nil then
  begin
    var Line := Format('maple port %d unit %d cmd %d words %d data0 %.8x', [Port, AUnit, Command, Words,
        Frame[Min(1, Words - 1)]]);
    if (Device = nil) or (Devices[Port, 0] = nil) then
      Line := Line + ' (none)';
    Trace.Add(Line);
  end;
  if (Device = nil) or (Devices[Port, 0] = nil) then
  begin
    Reply[0] := $FFFFFFFF;
    Exit(1);
  end;
  var Response: Byte;
  var Length := Device.Handle(Command, Recipient, @Frame[1], Words - 1, @Reply[1], Response);
  // The sender field names the device and the sockets that hold expansions.
  var Sender := Byte(Port shl 6);
  if AUnit = 0 then
  begin
    Sender := Sender or $20;
    for var U := 1 to 5 do
      if Devices[Port, U] <> nil then
        Sender := Sender or (1 shl (U - 1));
  end
  else
    Sender := Sender or (1 shl (AUnit - 1));
  Reply[0] := Cardinal(Response) or (Cardinal(Byte(Header shr 16)) shl 8) or (Cardinal(Sender) shl 16) or
    (Cardinal(Length) shl 24);
  Result := Length + 1;
  if (Trace <> nil) and (Command = 1) then
    Trace.Add(Format('  reply %.8x %.8x %.8x %.8x %.8x', [Reply[0], Reply[1], Reply[2], Reply[3], Reply[4]]));
end;

function TDCMaple.RunDMA(Table: Cardinal): Integer;
var
  Frame: array[0..255] of Cardinal;
  Reply: array[0..255] of Cardinal;
begin
  Result := 0;
  var RAM := FMemory.RAM;
  var Address := Table and $FFFFE0;
  for var Guard := 0 to 63 do
  begin
    var Control := PCardinal(RAM + (Address and $FFFFFC))^;
    var Pattern := (Control shr 8) and 7;
    var Port := Integer((Control shr 16) and 3);
    var Words := Integer(Control and $FF) + 1;
    if (Trace <> nil) and (Pattern <> 0) then
      Trace.Add(Format('maple pattern %d control %.8x', [Pattern, Control]));
    // Light gun mode: a gun on the port that sees the picture latches the
    // video counters.
    if (Pattern = 2) and (Devices[Port, 0] is TDCLightGun) and TDCLightGun(Devices[Port, 0]).OnScreen and
      Assigned(OnLightGun) then
      OnLightGun(TDCLightGun(Devices[Port, 0]).X, TDCLightGun(Devices[Port, 0]).Y);
    // Only normal transfers carry a receive address and a frame; other
    // patterns (light gun mode, NOP) are a single instruction word.
    var Destination: Cardinal := 0;
    if Pattern = 0 then
    begin
      Destination := PCardinal(RAM + ((Address + 4) and $FFFFFC))^;
      Inc(Address, 8);
    end
    else
      Inc(Address, 4);
    if Pattern = 0 then
    begin
      for var I := 0 to Words - 1 do
        Frame[I] := PCardinal(RAM + ((Address + Cardinal(I) * 4) and $FFFFFC))^;
      Inc(Address, Cardinal(Words) * 4);
      var Count := DispatchFrame(Port, @Frame[0], Words, @Reply[0]);
      var Target := Destination and $FFFFFC;
      for var I := 0 to Count - 1 do
        PCardinal(RAM + ((Target + Cardinal(I) * 4) and $FFFFFC))^ := Reply[I];
      FMemory.TouchRAM(Target, Cardinal(Count) * 4);
      Inc(Result, Words + Count);
    end;
    if (Control and $80000000) <> 0 then
      Break;
  end;
end;

procedure TDCMaple.SerializeState(Archive: TStateArchive);
begin
  for var P := 0 to 3 do
    for var U := 0 to 5 do
    begin
      var Present := Devices[P, U] <> nil;
      Archive.Field(Present, SizeOf(Present));
      if Present <> (Devices[P, U] <> nil) then
        raise EReadError.Create('Dreamcast snapshot Maple devices differ');
      if Present then
        Devices[P, U].SerializeState(Archive);
    end;
end;

end.

