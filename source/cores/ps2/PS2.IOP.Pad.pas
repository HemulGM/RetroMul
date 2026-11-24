unit PS2.IOP.Pad;

// DualShock 2 controllers and the high-level pad manager.
//
// TPS2DualShock2 is one controller as its serial protocol shows it. A packet
// is the peripheral byte 01h, a command and 00h; the reply is FFh, the mode
// id (41h digital, 73h analog, 79h analog with pressures, F3h in config
// mode) and 5Ah, then data. 42h reads the buttons, sticks and pressures, 43h
// enters or leaves config mode. In config mode 44h sets the mode and lock;
// 45h, 46h, 47h and 4Ch report the model, the actuators, the actuator
// combinations and the modes; 41h reports the buttons the pad can send, 4Fh
// chooses the ones it sends, 4Dh maps the motors and 40h sets up pressure
// sensing. Pads start in analog mode (as if the analog button had been
// pressed).
//
// TPS2PadMan stands in for the PADMAN and XPADMAN modules libpad talks to:
// the RPC servers (80000100h/80000101h, or 8000010Fh/8000011Fh of the ROM
// module whose commands are numbered 80000100h + n - 1), the result words
// where libpad reads them and the pad areas libpad hands over. An area holds
// two structures per pad; each field the manager writes one of them with a
// frame number above the other's. XPADMAN, which libpad initialises with
// command 10h, uses 128-byte structures with the data at +0, the ROM module
// 64-byte ones with the data at +8. libpad fills the data bytes of both
// structures with FFh before opening a pad, which also shows how far apart
// they are. Only slot 0 of each port has a pad (no multitap).
// References: ps2tek (controller commands), ps2sdk libpad and padman
// (AFL 2.0; RPC interface and structure layouts only).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  Core.Snapshots, PS2.Types, PS2.SIF;

const
  PS2PadSIDs: array[0..3] of Cardinal = ($80000100, $80000101, $8000010F, $8000011F);
  // IOP memory for the slots' request buffers (8 x 64 bytes, a free spot
  // of the high-level IOP's low memory).
  PS2PadIOPBuffers = $0000F800;

type
  // Front-end input for one pad: buttons active high in the pad bit order
  // (Select bit 0 .. Square bit 15), sticks right X/Y then left X/Y (80h
  // centre).
  TPS2PadState = record
    Buttons: Word;
    Axes: array[0..3] of Byte;
  end;

  TPS2DualShock2 = record
    // 41h, 73h or 79h (the id outside config mode).
    Id: Byte;
    Config, Locked: Boolean;
    // Bytes the pad sends after the header (4Fh): bit 0 the first button
    // byte .. bit 17 the R2 pressure.
    Report: Cardinal;
    Motors: array[0..5] of Byte;
    procedure Reset;
    procedure SetMode(Analog, Lock: Boolean);
    procedure SetReport(Mask: Cardinal);
    // The data of a 42h reply (buttons, then sticks, then pressures as the
    // mode has them); returns the count.
    function ReadData(const Input: TPS2PadState; Data: PByte): Integer;
    // One packet: Len command bytes in, Len reply bytes out.
    procedure Exchange(const Input: TPS2PadState; Cmd, Reply: PByte; Len: Integer);
  end;

  PPS2DualShock2 = ^TPS2DualShock2;

  TPS2PadFormat = (XPad, Rom64, Rom128);

  TPS2PadSlot = record
    // EE address of the two structures; 0 while closed.
    Area: Cardinal;
    Format: TPS2PadFormat;
    Frame: Cardinal;
    Mode, Lock: Byte;
    ActDirect, ActAlign: array[0..7] of Byte;
    ActDirectSet: Boolean;
  end;

  PPS2PadSlot = ^TPS2PadSlot;

  TPS2PadMan = class
  private
    FEERAM: PByte;
    FServers: TObjectList<TPS2RPCServer>;
    FSlots: array[0..1, 0..3] of TPS2PadSlot;
    // XPADMAN initialised (command 10h); its open-slot area.
    FInitialised: Boolean;
    FStatusArea, FStatusFrame: Cardinal;
    function DetectFormat(Area: Cardinal): TPS2PadFormat;
    procedure WriteSlot(Port, Slot: Integer);
    procedure WriteStatus;
  public
    Pads: array[0..1] of TPS2PadState;
    Devices: array[0..1] of TPS2DualShock2;
    // The module version reported to libpad: that of the PADMAN the game
    // loads, else the newest seen on game discs (4.05).
    Version: Word;
    // Diagnostics: calls when assigned.
    Log: TStrings;
    constructor Create(EERAM: PByte);
    destructor Destroy; override;
    procedure Reset;
    procedure AddServers(SIF: TPS2SIF);
    function Invoke(Args: PByte; Size, ReplySize: Integer): TBytes;
    // Once per field: the pads into the open areas.
    procedure Update;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  IdDigital = $41;
  IdAnalog = $73;
  IdPressure = $79;
  IdConfig = $F3;
  // Report bits: 2 button bytes, 4 stick bytes, 12 pressure bytes.
  ReportAnalog = $3F;
  ReportPressure = $3FFC0;
  // Pressure bytes: right, left, up, down, triangle, circle, cross, square,
  // L1, R1, L2, R2 (pad bits).
  PressureBits: array[0..11] of Word = ($0020, $0080, $0010, $0040, $1000, $2000, $4000, $8000, $0400, $0800,
    $0100, $0200);
  // Config mode replies (after the header).
  ModelReply: array[0..5] of Byte = ($03, $02, $01, $02, $01, $00);
  ActReply: array[0..1, 0..5] of Byte = (($00, $00, $01, $02, $00, $0A), ($00, $00, $01, $01, $01, $14));
  CombReply: array[0..5] of Byte = ($00, $00, $02, $00, $01, $00);
  ModeReply: array[0..1, 0..5] of Byte = (($00, $00, $00, $04, $00, $00), ($00, $00, $00, $07, $00, $00));
  PressureSetupReply: array[0..5] of Byte = ($00, $00, $02, $00, $00, $5A);
  ButtonsReply: array[0..5] of Byte = ($FF, $FF, $03, $00, $00, $5A);
  PollReply: array[0..5] of Byte = ($00, $00, $00, $00, $00, $5A);

  // libpad pad states and request states.
  StateDisconnected = 0;
  StateStable = 6;
  ReqComplete = 0;

  // XPADMAN pad structure (128 bytes).
  XData = $00;
  XActDirect = $20;
  XActAlign = $28;
  XActInfo = $30;
  XCombInfo = $40;
  XModeTable = $50;
  XFrame = $58;
  XLength = $60;
  XModeConfig = $64;
  XModeId = $65;
  XModel = $66;
  XDataReady = $67;
  XModes = $68;
  XModeOffset = $69;
  XActuators = $6A;
  XCombinations = $6B;
  XMode = $6D;
  XLock = $6E;
  XActDirectSize = $6F;
  XState = $70;
  XReqState = $71;
  XTask = $72;
  // The buttons the pad can send (the reply to command 41h, low byte
  // first): libpad versions without the RPC take the mask from here, and
  // only a pad that reports all 18 buttons enters pressure mode.
  XButtonMask = $79;
  XSize = $80;
  // ROM PADMAN pad structure (64 bytes).
  RFrame = $00;
  RState = $04;
  RReqState = $05;
  ROk = $06;
  RData = $08;
  RLength = $28;
  RConfig = $2D;
  RModel = $2E;
  RSize = $40;

  // Command numbers (ROM commands map to these).
  CmdOpen = $01;
  CmdInfoAct = $03;
  CmdInfoComb = $04;
  CmdInfoMode = $05;
  CmdSetMainMode = $06;
  CmdSetActDirect = $07;
  CmdSetActAlign = $08;
  CmdGetButtonMask = $09;
  CmdSetButtonInfo = $0A;
  CmdSetVref = $0B;
  CmdGetPortMax = $0C;
  CmdGetSlotMax = $0D;
  CmdClose = $0E;
  CmdEnd = $0F;
  CmdInit = $10;
  CmdGetModVersion = $12;
  DefaultVersion = $0405;

{ TPS2DualShock2 }

procedure TPS2DualShock2.Reset;
begin
  Id := IdAnalog;
  Config := False;
  Locked := False;
  Report := ReportAnalog;
  FillChar(Motors, SizeOf(Motors), $FF);
end;

procedure TPS2DualShock2.SetMode(Analog, Lock: Boolean);
begin
  Report := ReportAnalog;
  if Analog then
    Id := IdAnalog
  else
    Id := IdDigital;
  Locked := Lock;
end;

procedure TPS2DualShock2.SetReport(Mask: Cardinal);
begin
  if Id = IdDigital then
    Exit;
  Report := Mask and $3FFFF;
  if (Report and ReportPressure) <> 0 then
    Id := IdPressure
  else
    Id := IdAnalog;
end;

function TPS2DualShock2.ReadData(const Input: TPS2PadState; Data: PByte): Integer;
begin
  var Bits := not Input.Buttons;
  Data[0] := Byte(Bits);
  Data[1] := Byte(Bits shr 8);
  Result := 2;
  if Id = IdDigital then
    Exit;
  for var K := 0 to 3 do
    Data[2 + K] := Input.Axes[K];
  Result := 6;
  if Id <> IdPressure then
    Exit;
  for var K := 0 to 11 do
    if (Input.Buttons and PressureBits[K]) <> 0 then
      Data[6 + K] := $FF
    else
      Data[6 + K] := 0;
  Result := 18;
end;

procedure TPS2DualShock2.Exchange(const Input: TPS2PadState; Cmd, Reply: PByte; Len: Integer);
var
  out: array[0..31] of Byte;

  procedure Put(const Bytes: array of Byte);
  begin
    Move(Bytes[0], out[3], Length(Bytes));
  end;

begin
  FillChar(out, SizeOf(out), 0);
  out[0] := $FF;
  if Config then
    out[1] := IdConfig
  else
    out[1] := Id;
  out[2] := $5A;
  var C := 0;
  if Len > 1 then
    C := Cmd[1];
  var Arg: array[0..5] of Byte;
  for var K := 0 to 5 do
    if K + 3 < Len then
      Arg[K] := Cmd[K + 3]
    else
      Arg[K] := 0;
  // Outside config mode only 42h and 43h are understood.
  if not Config and (C <> $43) then
    C := $42;
  case C of
    $42:
      ReadData(Input, @out[3]);
    $43:
      begin
        // Leaving config mode answers with zeros; entering it, with the
        // buttons and sticks.
        if not Config then
        begin
          var Saved := Id;
          if Id = IdPressure then
            Id := IdAnalog;
          ReadData(Input, @out[3]);
          Id := Saved;
        end;
        Config := Arg[0] = 1;
      end;
    $40:
      Put(PressureSetupReply);
    $41:
      if Id <> IdDigital then
        Put(ButtonsReply);
    $44:
      if Arg[0] <= 1 then
        SetMode(Arg[0] = 1, Arg[1] = 3);
    $45:
      begin
        Put(ModelReply);
        out[5] := Ord(Id <> IdDigital);
      end;
    $46:
      if Arg[0] <= 1 then
        Put(ActReply[Arg[0]]);
    $47:
      if Arg[0] = 0 then
        Put(CombReply);
    $4C:
      if Arg[0] <= 1 then
        Put(ModeReply[Arg[0]]);
    $4D:
      begin
        Move(Motors, out[3], 6);
        Move(Arg, Motors, 6);
      end;
    $4F:
      begin
        Put(PollReply);
        SetReport(Arg[0] or (Cardinal(Arg[1]) shl 8) or (Cardinal(Arg[2]) shl 16));
      end;
  end;
  for var K := 0 to Len - 1 do
    if K < Length(out) then
      Reply[K] := out[K]
    else
      Reply[K] := 0;
end;

{ TPS2PadMan }

type
  TPS2PadServer = class(TPS2RPCServer)
  private
    FMan: TPS2PadMan;
  public
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
  end;

function TPS2PadServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  if (SID and $F) = $1 then
  begin
    // The extended services (80000101h, 8000011Fh) answer nothing.
    SetLength(Result, Max(ReplySize, Size));
    FillChar(Result[0], Length(Result), 0);
    Move(Args^, Result[0], Size);
  end
  else
    Result := FMan.Invoke(Args, Size, ReplySize);
end;

constructor TPS2PadMan.Create(EERAM: PByte);
begin
  inherited Create;
  FEERAM := EERAM;
  FServers := TObjectList<TPS2RPCServer>.Create(True);
  for var SID in PS2PadSIDs do
  begin
    var S := TPS2PadServer.Create(SID);
    S.FMan := Self;
    FServers.Add(S);
  end;
  for var P := 0 to 1 do
  begin
    Pads[P].Buttons := 0;
    FillChar(Pads[P].Axes, SizeOf(Pads[P].Axes), $80);
  end;
  Reset;
end;

destructor TPS2PadMan.Destroy;
begin
  FServers.Free;
  inherited;
end;

procedure TPS2PadMan.Reset;
begin
  FillChar(FSlots, SizeOf(FSlots), 0);
  FInitialised := False;
  FStatusArea := 0;
  FStatusFrame := 0;
  Version := DefaultVersion;
  for var P := 0 to 1 do
    Devices[P].Reset;
end;

procedure TPS2PadMan.AddServers(SIF: TPS2SIF);
begin
  for var S in FServers do
    SIF.AddServer(S);
end;

// The structure layout libpad prepared: the data bytes it filled with FFh.
function TPS2PadMan.DetectFormat(Area: Cardinal): TPS2PadFormat;

  function Filled(Offset: Cardinal): Boolean;
  begin
    var P := FEERAM + ((Area + Offset) and PS2RAMMask);
    for var K := 0 to 31 do
      if P[K] <> $FF then
        Exit(False);
    Result := True;
  end;

begin
  if Filled(XData) and Filled(XSize + XData) then
    Result := TPS2PadFormat.XPad
  else if Filled(RData) and Filled(2 * RSize + RData) then
    Result := TPS2PadFormat.Rom128
  else if Filled(RData) and Filled(RSize + RData) then
    Result := TPS2PadFormat.Rom64
  else if FInitialised then
    Result := TPS2PadFormat.XPad
  else
    Result := TPS2PadFormat.Rom64;
end;

// The next structure of a pad: the one the older frame number is in.
procedure TPS2PadMan.WriteSlot(Port, Slot: Integer);
var
  Data: array[0..31] of Byte;
begin
  var S: PPS2PadSlot := @FSlots[Port, Slot];
  if S.Area = 0 then
    Exit;
  Inc(S.Frame);
  var Stride: Cardinal := XSize;
  if S.Format = TPS2PadFormat.Rom64 then
    Stride := RSize;
  var Address := (S.Area + (S.Frame and 1) * Stride) and PS2RAMMask;
  if Address > PS2RAMSize - XSize then
    Exit;
  var P := FEERAM + Address;
  var Connected := Slot = 0;
  var Dev: PPS2DualShock2 := @Devices[Port];
  // Data: 00h, the mode id, the pad's reply data; 5Ah last.
  FillChar(Data, SizeOf(Data), 0);
  if Connected then
  begin
    Data[1] := Dev.Id;
    Dev.ReadData(Pads[Port], @Data[2]);
    Data[31] := $5A;
  end
  else
    Data[0] := $FF;
  if S.Format = TPS2PadFormat.XPad then
  begin
    FillChar(P^, XSize, 0);
    Move(Data, P[XData], 32);
    PCardinal(P + XFrame)^ := S.Frame;
    P[XState] := StateDisconnected;
    P[XReqState] := ReqComplete;
    // Task: updating the pad.
    P[XTask] := 1;
    if not Connected then
      Exit;
    Move(S.ActDirect, P[XActDirect], 8);
    Move(S.ActAlign, P[XActAlign], 8);
    // Actuator and combination tables, the mode table (digital, analog).
    for var A := 0 to 1 do
      Move(ActReply[A, 2], P[XActInfo + A * 4], 4);
    Move(CombReply[2], P[XCombInfo], 4);
    PWord(P + XModeTable)^ := ModeReply[0, 3];
    PWord(P + XModeTable + 2)^ := ModeReply[1, 3];
    PCardinal(P + XLength)^ := 32;
    // Mode configuration: the pad has config mode and answered it.
    P[XModeConfig] := 2;
    P[XModeId] := Dev.Id;
    P[XModel] := ModelReply[0];
    P[XDataReady] := 1;
    P[XModes] := ModelReply[1];
    P[XModeOffset] := Ord(Dev.Id <> IdDigital);
    P[XActuators] := ModelReply[3];
    P[XCombinations] := ModelReply[4];
    P[XMode] := S.Mode;
    P[XLock] := S.Lock;
    if S.ActDirectSet then
      P[XActDirectSize] := 6;
    Move(ButtonsReply[0], P[XButtonMask], 3);
    P[XState] := StateStable;
  end
  else
  begin
    FillChar(P^, RSize, 0);
    PCardinal(P + RFrame)^ := S.Frame;
    Move(Data, P[RData], 32);
    P[RState] := StateStable;
    P[RReqState] := ReqComplete;
    P[ROk] := 1;
    PCardinal(P + RLength)^ := 32;
    // Config mode present (2), model.
    P[RConfig] := 2;
    P[RModel] := ModelReply[0];
  end;
end;

// The open-slot words XPADMAN keeps for libpad (frame, slots of port 0
// and 1), two copies written alternately.
procedure TPS2PadMan.WriteStatus;
begin
  if FStatusArea = 0 then
    Exit;
  Inc(FStatusFrame);
  var Address := FStatusArea;
  if not Odd(FStatusFrame) then
    Inc(Address, 128);
  Address := Address and PS2RAMMask;
  if Address > PS2RAMSize - 128 then
    Exit;
  var P := PCardinal(FEERAM + Address);
  P[0] := FStatusFrame;
  for var Port := 0 to 1 do
  begin
    var Open: Cardinal := 0;
    for var Slot := 0 to 3 do
      if FSlots[Port, Slot].Area <> 0 then
        Open := Open or (Cardinal(1) shl Slot);
    P[1 + Port] := Open;
  end;
end;

// Arguments: command, port, slot, then the command's own words. Results
// go into the returned copy of the buffer.
function TPS2PadMan.Invoke(Args: PByte; Size, ReplySize: Integer): TBytes;
begin
  SetLength(Result, Max(Max(ReplySize, Size), 32));
  FillChar(Result[0], Length(Result), 0);
  Move(Args^, Result[0], Min(Size, Length(Result)));
  var A := PCardinal(@Result[0]);
  var Cmd := A[0];
  if Log <> nil then
    Log.Add(Format('pad %.8x port %d slot %d %.8x %.8x', [Cmd, A[1], A[2], A[3], A[4]]));
  var Rom := (Cmd and $80000000) <> 0;
  if Rom then
    Cmd := (Cmd and $FF) + 1;
  var Port := Integer(A[1]);
  var Slot := Integer(A[2]);
  var Valid := (A[1] < 2) and (A[2] < 4);
  case Cmd of
    CmdOpen:
      begin
        // The ROM module has no multitap slots.
        if Valid and not (Rom and (Slot > 0)) then
        begin
          var S: PPS2PadSlot := @FSlots[Port, Slot];
          S^ := Default(TPS2PadSlot);
          S.Area := A[4] and PS2RAMMask;
          S.Format := DetectFormat(S.Area);
          FillChar(S.ActAlign, SizeOf(S.ActAlign), $FF);
          WriteSlot(Port, Slot);
          A[3] := 1;
          // An IOP buffer per slot (two 32-byte halves) older libpads send
          // their requests to by SIF DMA every frame; the HLE module does
          // not read it.
          A[5] := PS2PadIOPBuffers + Cardinal(Port * 4 + Slot) * $40;
        end;
      end;
    CmdClose:
      begin
        if Valid then
          FSlots[Port, Slot].Area := 0;
        A[3] := 1;
      end;
    CmdEnd:
      begin
        FillChar(FSlots, SizeOf(FSlots), 0);
        A[3] := 1;
      end;
    CmdInit:
      begin
        FInitialised := True;
        FStatusArea := A[4] and PS2RAMMask;
        A[3] := 1;
      end;
    CmdGetModVersion:
      A[3] := Version;
    CmdGetPortMax:
      A[3] := 2;
    CmdGetSlotMax:
      A[3] := 1;
    CmdSetMainMode:
      // Mode 0 digital, 1 analog; lock 3 keeps the analog button off.
      if Valid and (Slot = 0) and (A[3] <= 1) then
      begin
        FSlots[Port, Slot].Mode := Byte(A[3]);
        FSlots[Port, Slot].Lock := Byte(A[4]);
        Devices[Port].SetMode(A[3] = 1, A[4] = 3);
        A[5] := 1;
      end;
    CmdInfoMode:
      if Valid and (Slot = 0) then
      begin
        // 1: id, 2: extended id, 3: mode table offset, 4: mode table entry
        // (index -1: entries).
        var Analog := Ord(Devices[Port].Id <> IdDigital);
        case A[3] of
          1:
            A[5] := Devices[Port].Id shr 4;
          2:
            A[5] := ModeReply[Analog, 3];
          3:
            A[5] := Analog;
          4:
            if A[4] = $FFFFFFFF then
              A[5] := 2
            else if A[4] <= 1 then
              A[5] := ModeReply[A[4], 3];
        end;
      end;
    CmdInfoAct:
      if Valid and (Slot = 0) then
      begin
        // Actuator -1: count; else bytes 1..4 of its description.
        var Act := Integer(A[3]);
        if Act = -1 then
          A[5] := 2
        else if (Act >= 0) and (Act <= 1) and (A[4] >= 1) and (A[4] <= 4) then
          A[5] := ActReply[Act, 1 + A[4]]
        else
          A[5] := Cardinal(-1);
      end;
    CmdInfoComb:
      if Valid and (Slot = 0) then
      begin
        // List -1: count; else bytes -1..2 of the combination.
        var List := Integer(A[3]);
        var Offset := Integer(A[4]);
        if List = -1 then
          A[5] := 1
        else if (List = 0) and (Offset >= -1) and (Offset <= 2) then
          A[5] := CombReply[3 + Offset]
        else
          A[5] := Cardinal(-1);
      end;
    CmdSetActDirect:
      if Valid and (Slot = 0) then
      begin
        Move(A[3], FSlots[Port, Slot].ActDirect, 6);
        FSlots[Port, Slot].ActDirectSet := True;
        A[5] := 1;
      end;
    CmdSetActAlign:
      if Valid and (Slot = 0) then
      begin
        Move(A[3], FSlots[Port, Slot].ActAlign, 6);
        A[5] := 1;
      end;
    CmdGetButtonMask:
      if Valid and (Slot = 0) then
        A[3] := ButtonsReply[0] or (Cardinal(ButtonsReply[1]) shl 8) or (Cardinal(ButtonsReply[2]) shl 16);
    CmdSetButtonInfo:
      if Valid and (Slot = 0) then
      begin
        // Pressure bytes to send (bit 0 right .. bit 11 R2).
        Devices[Port].SetReport((A[3] shl 6) or ReportAnalog);
        A[4] := 1;
      end;
    CmdSetVref:
      if Valid and (Slot = 0) then
        A[7] := 1;
  end;
end;

procedure TPS2PadMan.Update;
begin
  for var P := 0 to 1 do
    for var S := 0 to 3 do
      WriteSlot(P, S);
  WriteStatus;
end;

procedure TPS2PadMan.SerializeState(State: TStateArchive);
begin
  State.Field(FSlots, SizeOf(FSlots));
  State.Field(FInitialised, SizeOf(FInitialised));
  State.Field(FStatusArea, SizeOf(FStatusArea));
  State.Field(FStatusFrame, SizeOf(FStatusFrame));
  State.Field(Devices, SizeOf(Devices));
  State.Field(Version, SizeOf(Version));
end;

end.

