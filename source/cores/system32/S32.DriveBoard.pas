unit S32.DriveBoard;

// Jurassic Park cabinet board: execute EPR-13908 on RetroMul's Z80.
// The ROM's CXD1095 A input receives inverted main-board port G; D's low
// nibble is returned on main-board port C. No game ROM patch is applied.
// The board oscillator/interrupt source and motor plant remain unmeasured;
// the current 4 MHz / 1 kHz scheduling is provisional, not cycle verified.
interface

uses
  System.SysUtils, HW.Z80, Core.Snapshots;

type
  TS32DriveBoard = class
  private
    FROM: TBytes;
    FRAM: array[0..$3FFF] of Byte;
    FPorts, FDirection: array[0..4] of Byte;
    FCPU: TZ80State;
    FBus: TZ80ReadAndWriteCallbacks;
    FCommand: Byte;
    FTime, FNextIRQ: Int64;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure WritePort(Port, Value: Byte);
    function GetReply: Byte;
  public
    constructor Create(const ROM: TBytes);
    procedure Reset;
    procedure RunUntil(MainClock: Int64);
    procedure SerializeState(State: TStateArchive);
    property Command: Byte read FCommand write FCommand;
    property Reply: Byte read GetReply;
    property CPU: TZ80State read FCPU;
  end;

implementation

uses
  System.Classes;

function DriveRead(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TS32DriveBoard(User).ReadMemory(Word(Address));
end;

procedure DriveWrite(User: Pointer; Address, Value: Cardinal);
begin
  TS32DriveBoard(User).WriteMemory(Word(Address), Byte(Value));
end;

function DriveIn(User: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TS32DriveBoard(User).ReadPort(Byte(Address));
end;

procedure DriveOut(User: Pointer; Address, Value: Cardinal);
begin
  TS32DriveBoard(User).WritePort(Byte(Address), Byte(Value));
end;

constructor TS32DriveBoard.Create(const ROM: TBytes);
begin
  inherited Create;
  if Length(ROM) < $8000 then
    raise EReadError.Create('Missing EPR-13908 drive board firmware');
  FROM := ROM;
  FBus := Default(TZ80ReadAndWriteCallbacks);
  FBus.UserData := Self;
  FBus.ReadCallback := DriveRead;
  FBus.WriteCallback := DriveWrite;
  FBus.PortReadCallback := DriveIn;
  FBus.PortWriteCallback := DriveOut;
  Reset;
end;

procedure TS32DriveBoard.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FPorts, SizeOf(FPorts), $FF);
  FillChar(FDirection, SizeOf(FDirection), $FF);
  FCommand := 0;
  FTime := 0;
  FNextIRQ := 4000;
  Z80StateInitialise(FCPU);
end;

function TS32DriveBoard.ReadMemory(Address: Word): Byte;
begin
  if Address < $8000 then
    Exit(FROM[Address]);
  if Address < $C000 then
    Exit(FRAM[Address and $3FFF]);
  if Address = $C000 then
    Exit(0); // normal command mode, local test disabled
  Result := $FF;
end;

procedure TS32DriveBoard.WriteMemory(Address: Word; Value: Byte);
begin
  if (Address >= $8000) and (Address < $C000) then
    FRAM[Address and $3FFF] := Value;
end;

function TS32DriveBoard.ReadPort(Port: Byte): Byte;
begin
  Result := 0;
  if Port >= 5 then
    Exit;
  var Input: Byte := $FF;
  if Port = 0 then
    Input := not FCommand;
  Result := (Input and FDirection[Port]) or (FPorts[Port] and not FDirection[Port]);
  if Port = 4 then
    Result := Result and 15;
end;

procedure TS32DriveBoard.WritePort(Port, Value: Byte);
begin
  if Port < 5 then
  begin
    FPorts[Port] := Value;
    if Port = 4 then
    begin
      FPorts[4] := Value and 15;
      if Value and 1 = 0 then
        Z80Interrupt(FCPU, 0);
    end;
  end
  else if Port = 6 then
    for var P := 0 to 3 do
      FDirection[P] := ($0F * Ord(Value and (1 shl (P * 2)) <> 0)) or ($F0 * Ord(Value and (2 shl (P * 2)) <> 0))
  else if Port = 7 then
    FDirection[4] := (Value and 15) or $F0;
end;

function TS32DriveBoard.GetReply: Byte;
begin
  Result := (FPorts[3] or FDirection[3]) and 15;
end;

procedure TS32DriveBoard.RunUntil(MainClock: Int64);
begin
  var Target := MainClock * 4000000 div 16107950;
  while FTime < Target do
  begin
    if FTime >= FNextIRQ then
    begin
      Inc(FNextIRQ, 4000);
      Z80Interrupt(FCPU, 1);
    end;
    Inc(FTime, Z80DoInstruction(FCPU, FBus));
  end;
end;

procedure TS32DriveBoard.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPorts, SizeOf(FPorts));
  State.Field(FDirection, SizeOf(FDirection));
  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FNextIRQ, SizeOf(FNextIRQ));
  if (FTime < 0) or (FNextIRQ < FTime - 4000) then
    raise EReadError.Create('Invalid System 32 drive board state');
end;

end.

