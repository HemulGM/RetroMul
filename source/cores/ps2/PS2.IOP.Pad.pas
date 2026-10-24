unit PS2.IOP.Pad;

// High-level PADMAN (DualShock 2 manager): the RPC servers libpad binds
// (80000100h, 80000101h, 8000010Fh, 8000011Fh), the pad areas libpad opens
// in EE RAM (two double-buffered pad structures per port) and their button,
// stick and pressure bytes, refreshed every field. Three area layouts are
// told apart by the fill pattern libpad leaves: 64-byte, 128-byte (64 used)
// and the extended 128-byte layout of newer libraries.
// Protocol and layouts after Play! (BSD-2, Iop_PadMan).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, PS2.Types, PS2.SIF;

const
  PS2PadSIDs: array[0..3] of Cardinal = ($80000100, $80000101, $8000010F, $8000011F);

type
  // One DualShock 2: buttons active high in the pad bit order (Select bit 0
  // .. Square bit 15), sticks right X/Y then left X/Y (80h centre).
  TPS2PadState = record
    Buttons: Word;
    Axes: array[0..3] of Byte;
  end;

  TPS2PadLayout = (Standard, Standard128, Extended);

  TPS2PadMan = class
  private
    FEERAM: PByte;
    FServers: TObjectList<TPS2RPCServer>;
    FLayout: TPS2PadLayout;
    FArea: array[0..1] of Cardinal;
    FMode: array[0..1] of Byte;
    function StructAddress(Port, Index: Integer): Cardinal;
    function DataAddress(Port, Index: Integer): Cardinal;
    procedure InitStruct(Port, Index: Integer);
    procedure WriteData(Port: Integer);
    function DetectLayout(Address: Cardinal): TPS2PadLayout;
  public
    Pads: array[0..1] of TPS2PadState;
    // Diagnostics: calls when assigned.
    Log: TStrings;
    constructor Create(EERAM: PByte);
    destructor Destroy; override;
    procedure Reset;
    procedure AddServers(SIF: TPS2SIF);
    function Invoke(Args: PByte; Size, ReplySize: Integer): TBytes;
    // Once per field: the current pad states into the open areas.
    procedure Update;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  ModeDigital = 4;
  ModeDualShock = 7;
  // Pressure bytes 8..19: right, left, up, down, triangle, circle, cross,
  // square, L1, R1, L2, R2 (pad bits).
  PressureBits: array[0..11] of Word = ($0020, $0080, $0010, $0040, $1000, $2000, $4000, $8000, $0400, $0800,
    $0100, $0200);

type
  TPS2PadArgs = array[0..7] of Cardinal;
  PPS2PadArgs = ^TPS2PadArgs;

  TPS2PadServer = class(TPS2RPCServer)
  private
    FMan: TPS2PadMan;
  public
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
  end;

function TPS2PadServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  Result := FMan.Invoke(Args, Size, ReplySize);
end;

{ TPS2PadMan }

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
  FLayout := TPS2PadLayout.Standard;
  FArea[0] := 0;
  FArea[1] := 0;
  FMode[0] := ModeDualShock;
  FMode[1] := ModeDualShock;
end;

procedure TPS2PadMan.AddServers(SIF: TPS2SIF);
begin
  for var S in FServers do
    SIF.AddServer(S);
end;

function TPS2PadMan.DetectLayout(Address: Cardinal): TPS2PadLayout;
begin
  var P := FEERAM + (Address and PS2RAMMask);
  Result := TPS2PadLayout.Standard;
  if (P[$08] = $FF) and (P[$88] = $FF) then
    Result := TPS2PadLayout.Standard128;
  if (P[$00] = $FF) and (P[$80] = $FF) then
    Result := TPS2PadLayout.Extended;
end;

function TPS2PadMan.StructAddress(Port, Index: Integer): Cardinal;
begin
  if FLayout = TPS2PadLayout.Standard then
    Result := FArea[Port] + Cardinal(Index) * $40
  else
    Result := FArea[Port] + Cardinal(Index) * $80;
  Result := Result and PS2RAMMask;
  if Result > PS2RAMSize - $80 then
    Result := PS2RAMSize - $80;
end;

// The 32 data bytes: +8 in the standard structures, +0 in the extended one.
function TPS2PadMan.DataAddress(Port, Index: Integer): Cardinal;
begin
  Result := StructAddress(Port, Index);
  if FLayout <> TPS2PadLayout.Extended then
    Inc(Result, 8);
end;

procedure TPS2PadMan.InitStruct(Port, Index: Integer);
begin
  var S := FEERAM + StructAddress(Port, Index);
  var D := FEERAM + DataAddress(Port, Index);
  if FLayout = TPS2PadLayout.Extended then
  begin
    PCardinal(S + $58)^ := Cardinal(Index);
    PCardinal(S + $60)^ := 32;
    S[$70] := 6;
    S[$71] := 0;
    S[$72] := 1;
    if Index = 1 then
    begin
      S[$65] := ModeDualShock shl 4;
      S[$69] := 0;
      PWord(S + $50)^ := ModeDualShock;
      S[$68] := 4;
    end;
  end
  else
  begin
    PCardinal(S)^ := Cardinal(Index);
    S[4] := 6;
    S[5] := 0;
    S[6] := 1;
    PCardinal(S + $28)^ := 32;
  end;
  for var K := 4 to 7 do
    D[K] := $7F;
  if Index = 1 then
  begin
    D[0] := 0;
    D[1] := FMode[Port] shl 4;
  end;
end;

procedure TPS2PadMan.WriteData(Port: Integer);
begin
  if FArea[Port] = 0 then
    Exit;
  var D := FEERAM + DataAddress(Port, 1);
  var Pad := Pads[Port];
  var Bits := not Pad.Buttons;
  D[0] := 0;
  D[1] := FMode[Port] shl 4;
  D[2] := Byte(Bits);
  D[3] := Byte(Bits shr 8);
  for var K := 0 to 3 do
    D[4 + K] := Pad.Axes[K];
  for var K := 0 to 11 do
    if (Pad.Buttons and PressureBits[K]) <> 0 then
      D[8 + K] := $FF
    else
      D[8 + K] := 0;
  var S := FEERAM + StructAddress(Port, 1);
  if FLayout = TPS2PadLayout.Extended then
    S[$71] := 0
  else
    S[5] := 0;
end;

function TPS2PadMan.Invoke(Args: PByte; Size, ReplySize: Integer): TBytes;
begin
  SetLength(Result, Max(ReplySize, 32));
  FillChar(Result[0], Length(Result), 0);
  var A := PPS2PadArgs(Args);
  var Method := A[0];
  var Port := Integer(A[1] and 1);
  if Log <> nil then
    Log.Add(Format('pad %.8x port %d slot %d %.8x %.8x', [Method, A[1], A[2], A[3], A[4]]));
  case Method of
    $00000001, $80000100:
      begin
        // Open(port, slot, ..., pad area)
        if A[1] < 2 then
        begin
          FArea[Port] := A[4] and PS2RAMMask;
          FLayout := DetectLayout(FArea[Port]);
          InitStruct(Port, 0);
          InitStruct(Port, 1);
          WriteData(Port);
        end;
        PCardinal(@Result[12])^ := 1;
      end;
    $80000105:
      begin
        // SetMainMode(port, slot, mode, lock)
        if A[1] < 2 then
        begin
          if A[3] <> 0 then
            FMode[Port] := ModeDualShock
          else
            FMode[Port] := ModeDigital;
          WriteData(Port);
        end;
        PCardinal(@Result[12])^ := 1;
      end;
    $8000010D:
      begin
        if A[1] < 2 then
          FArea[Port] := 0;
        PCardinal(@Result[12])^ := 1;
      end;
    $00000008:
      PCardinal(@Result[20])^ := 1;
    $00000010:
      PCardinal(@Result[12])^ := 1;
    $00000012:
      PCardinal(@Result[12])^ := $400;
  end;
end;

procedure TPS2PadMan.Update;
begin
  for var P := 0 to 1 do
    WriteData(P);
end;

procedure TPS2PadMan.SerializeState(State: TStateArchive);
begin
  State.Field(FLayout, SizeOf(FLayout));
  State.Field(FArea, SizeOf(FArea));
  State.Field(FMode, SizeOf(FMode));
end;

end.
