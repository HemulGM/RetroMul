unit PS2.SIF;

// Subsystem interface between the EE and the IOP: the MSCOM/SMCOM/MSFLG/SMFLG
// registers, EE-to-IOP transfers (SIF1) and IOP-to-EE packets (SIF0, through
// DMAC channel 5 in destination-chain mode), and the IOP side of the SIF
// command protocol (sifcmd/sifrpc) for the high-level IOP: system commands,
// RPC bind/call/other-data and the RPC servers (TPS2RPCServer).
// The EE libraries (sifcmd/sifrpc in libkernel) run unchanged on the EE.
// References: ps2sdk sifcmd/sifrpc (AFL 2.0, interfaces only), Play!
// (BSD-2, Iop_SifMan / SIF), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, PS2.Types, PS2.Scheduler,
  PS2.DMAC;

const
  SIFCmdChangeSAddr = $80000000;
  SIFCmdSetSReg = $80000001;
  SIFCmdInit = $80000002;
  SIFCmdReset = $80000003;
  SIFCmdRPCEnd = $80000008;
  SIFCmdRPCBind = $80000009;
  SIFCmdRPCCall = $8000000A;
  SIFCmdRPCRData = $8000000C;

  SIFStatSIFInit = $10000;
  SIFStatCmdInit = $20000;
  SIFStatBootEnd = $40000;

  // IOP RAM used by the high-level IOP side: the command receive buffer and
  // the RPC server buffers.
  SIFIOPCmdBuffer = $00010000;
  SIFIOPServerData = $00010100;
  SIFIOPServerBuffers = $00012000;
  SIFIOPServerBufferSize = $4000;

type
  TPS2SIF = class;

  // A high-level RPC server. Call runs function Fn with the arguments the EE
  // sent (Args, Size bytes in IOP RAM) and returns the reply bytes (at most
  // the EE's receive size).
  TPS2RPCServer = class
  private
    FSID: Cardinal;
    FIndex: Integer;
  protected
    FSIF: TPS2SIF;
  public
    constructor Create(SID: Cardinal);
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; virtual; abstract;
    procedure Reset; virtual;
    procedure SerializeState(State: TStateArchive); virtual;
    property SID: Cardinal read FSID;
  end;

  // Answers every call with zeros (modules the high-level IOP lacks).
  TPS2StubServer = class(TPS2RPCServer)
  public
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
  end;

  TPS2SIFChunk = record
    Dest: Cardinal;
    Data: TBytes;
    IRQ: Boolean;
  end;

  // RPC bind or call for a server that is not high-level (an IOP module's,
  // through the IOP side): Kind is the command id, Packet the EE packet.
  TPS2SIFGuestCommand = procedure(Kind: Cardinal; const Packet: TBytes) of object;
  TPS2SIFReset = procedure(const Args: string) of object;

  TPS2SIF = class
  private
    FScheduler: TPS2Scheduler;
    FDMAC: TPS2DMAC;
    FEERAM, FIOPRAM: PByte;
    FQueue: TList<TPS2SIFChunk>;
    FServers: TObjectList<TPS2RPCServer>;
    FStubs: TObjectList<TPS2RPCServer>;
    FOnReset: TPS2SIFReset;
    FOnGuestCommand: TPS2SIFGuestCommand;
    procedure Command(Address: Cardinal);
    procedure Bind(const P: TBytes);
    procedure Call(const P: TBytes);
    procedure OtherData(const P: TBytes);
    function FindServer(SID: Cardinal): TPS2RPCServer;
    function IOP32(Address: Cardinal): Cardinal;
  public
    MSCOM, SMCOM, MSFLG, SMFLG, CTRL, BD6: Cardinal;
    // EE address of the EE's command receive buffer (pktbuf).
    EERecvAddr: Cardinal;
    // Latency of an IOP reply in EE cycles.
    ReplyDelay: Int64;
    // Diagnostics: commands, binds and calls when assigned.
    Log: TStrings;
    // Unknown SIDs get empty servers (until IOP modules run).
    StubUnknownServers: Boolean;
    constructor Create(Scheduler: TPS2Scheduler; DMAC: TPS2DMAC; EERAM, IOPRAM: PByte);
    destructor Destroy; override;
    procedure Reset;
    // IOP side ready (after power-on or an IOP reset).
    procedure IOPBooted;
    procedure AddServer(Server: TPS2RPCServer);
    procedure RemoveServers;
    // EE-side registers (SifSetReg/SifGetReg and MMIO 1000F2x0h).
    function ReadRegister(Index: Cardinal): Cardinal;
    procedure WriteRegister(Index, Value: Cardinal);
    // An EE-to-IOP transfer (SifSetDma): Size bytes from EE physical Src to
    // IOP Dest; commands to the IOP command buffer run on arrival.
    procedure EEToIOP(Src, Dest: Cardinal; Size: Integer; Attr: Cardinal);
    // IOP-to-EE: data chunks then a command packet for the EE's buffer.
    procedure SendData(Dest: Cardinal; const Data: TBytes);
    procedure SendCommand(Cid: Cardinal; Packet: TBytes; NoIRQ: Boolean = False; Dest: Cardinal = 0);
    // Delivers queued packets while DMAC channel 5 is armed.
    procedure Deliver;
    procedure SerializeState(State: TStateArchive);
    property EERAM: PByte read FEERAM;
    property IOPRAM: PByte read FIOPRAM;
    property OnReset: TPS2SIFReset read FOnReset write FOnReset;
    property OnGuestCommand: TPS2SIFGuestCommand read FOnGuestCommand write FOnGuestCommand;
  end;

function PacketU32(const P: TBytes; Offset: Integer): Cardinal; inline;
procedure SetPacketU32(var P: TBytes; Offset: Integer; Value: Cardinal); inline;

implementation

function PacketU32(const P: TBytes; Offset: Integer): Cardinal;
begin
  if Offset + 4 > Length(P) then
    Exit(0);
  Result := PCardinal(@P[Offset])^;
end;

procedure SetPacketU32(var P: TBytes; Offset: Integer; Value: Cardinal);
begin
  if Offset + 4 > Length(P) then
    SetLength(P, Offset + 4);
  PCardinal(@P[Offset])^ := Value;
end;

{ TPS2RPCServer }

constructor TPS2RPCServer.Create(SID: Cardinal);
begin
  inherited Create;
  FSID := SID;
end;

procedure TPS2RPCServer.Reset;
begin
end;

procedure TPS2RPCServer.SerializeState(State: TStateArchive);
begin
end;

{ TPS2StubServer }

function TPS2StubServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  SetLength(Result, Max(ReplySize, 4));
  FillChar(Result[0], Length(Result), 0);
end;

{ TPS2SIF }

constructor TPS2SIF.Create(Scheduler: TPS2Scheduler; DMAC: TPS2DMAC; EERAM, IOPRAM: PByte);
begin
  inherited Create;
  FScheduler := Scheduler;
  FDMAC := DMAC;
  FEERAM := EERAM;
  FIOPRAM := IOPRAM;
  FQueue := TList<TPS2SIFChunk>.Create;
  FServers := TObjectList<TPS2RPCServer>.Create(False);
  FStubs := TObjectList<TPS2RPCServer>.Create(True);
  ReplyDelay := 3000;
  Reset;
end;

destructor TPS2SIF.Destroy;
begin
  FQueue.Free;
  FServers.Free;
  FStubs.Free;
  inherited;
end;

procedure TPS2SIF.Reset;
begin
  MSCOM := 0;
  SMCOM := 0;
  MSFLG := 0;
  SMFLG := 0;
  CTRL := 0;
  BD6 := 0;
  EERecvAddr := 0;
  FQueue.Clear;
  FScheduler.Cancel(TPS2Event.SIF);
end;

procedure TPS2SIF.IOPBooted;
begin
  SMCOM := SIFIOPCmdBuffer;
  SMFLG := SMFLG or SIFStatSIFInit or SIFStatCmdInit or SIFStatBootEnd;
end;

procedure TPS2SIF.AddServer(Server: TPS2RPCServer);
begin
  Server.FSIF := Self;
  Server.FIndex := FServers.Count;
  FServers.Add(Server);
end;

procedure TPS2SIF.RemoveServers;
begin
  FServers.Clear;
  FStubs.Clear;
end;

function TPS2SIF.FindServer(SID: Cardinal): TPS2RPCServer;
begin
  for var S in FServers do
    if S.SID = SID then
      Exit(S);
  Result := nil;
end;

function TPS2SIF.IOP32(Address: Cardinal): Cardinal;
begin
  Result := PCardinal(FIOPRAM + (Address and (PS2IOPRAMMask and not 3)))^;
end;

function TPS2SIF.ReadRegister(Index: Cardinal): Cardinal;
begin
  case Index of
    1: Result := MSCOM;
    2: Result := SMCOM;
    3: Result := MSFLG;
    4: Result := SMFLG;
    5: Result := CTRL;
    6: Result := BD6;
  else
    Result := 0;
  end;
end;

procedure TPS2SIF.WriteRegister(Index, Value: Cardinal);
begin
  case Index of
    1: MSCOM := Value;
    // SMCOM belongs to the IOP.
    3: MSFLG := MSFLG or Value;
    4: SMFLG := SMFLG and not Value;
    5: CTRL := Value;
    6: BD6 := Value;
  end;
end;

procedure TPS2SIF.EEToIOP(Src, Dest: Cardinal; Size: Integer; Attr: Cardinal);
begin
  if Size <= 0 then
    Exit;
  var Bytes := (Size + 15) and not 15;
  var S := Src and PS2RAMMask;
  var D := Dest and PS2IOPRAMMask;
  if S + Cardinal(Bytes) > PS2RAMSize then
    Bytes := Integer(PS2RAMSize - S);
  if D + Cardinal(Bytes) > PS2IOPRAMSize then
    Bytes := Integer(PS2IOPRAMSize - D);
  Move((FEERAM + S)^, (FIOPRAM + D)^, Bytes);
  if D = SIFIOPCmdBuffer then
    Command(D);
end;

procedure TPS2SIF.SendData(Dest: Cardinal; const Data: TBytes);
begin
  if Length(Data) = 0 then
    Exit;
  var C: TPS2SIFChunk;
  C.Dest := Dest;
  C.Data := Data;
  C.IRQ := False;
  FQueue.Add(C);
end;

procedure TPS2SIF.SendCommand(Cid: Cardinal; Packet: TBytes; NoIRQ: Boolean; Dest: Cardinal);
begin
  if Length(Packet) < 16 then
    SetLength(Packet, 16);
  // Header: psize (8 bits) and dsize, dest, cid, opt.
  PCardinal(@Packet[0])^ := Cardinal(Length(Packet)) and $FF;
  PCardinal(@Packet[4])^ := 0;
  PCardinal(@Packet[8])^ := Cid;
  var C: TPS2SIFChunk;
  if Dest = 0 then
    Dest := EERecvAddr;
  C.Dest := Dest;
  C.Data := Packet;
  C.IRQ := not NoIRQ;
  FQueue.Add(C);
  if not FScheduler.Pending(TPS2Event.SIF) then
    FScheduler.Schedule(TPS2Event.SIF, FScheduler.Now + ReplyDelay);
end;

procedure TPS2SIF.Deliver;
begin
  while FQueue.Count > 0 do
  begin
    var C := FQueue[0];
    if C.IRQ and not FDMAC.SIF0Ready then
      Exit;
    FQueue.Delete(0);
    if Length(C.Data) > 0 then
      FDMAC.SIF0Write(C.Dest, @C.Data[0], Length(C.Data), C.IRQ)
    else
      FDMAC.SIF0Write(C.Dest, nil, 0, C.IRQ);
    // One interrupting packet at a time: the EE re-arms channel 5 from its
    // handler.
    if C.IRQ then
      Break;
  end;
  if FQueue.Count > 0 then
    FScheduler.Schedule(TPS2Event.SIF, FScheduler.Now + ReplyDelay div 4);
end;

procedure TPS2SIF.Command(Address: Cardinal);
begin
  var Size := Integer(IOP32(Address) and $FF);
  if Size < 16 then
    Size := 16;
  if Size > 128 then
    Size := 128;
  var P: TBytes;
  SetLength(P, Size);
  Move((FIOPRAM + Address)^, P[0], Size);
  var Cid := PacketU32(P, 8);
  if Log <> nil then
    Log.Add(Format('sif cmd %.8x sid/fn %.8x/%.8x', [Cid, PacketU32(P, 32), PacketU32(P, 32)]));
  case Cid of
    SIFCmdChangeSAddr:
      EERecvAddr := PacketU32(P, 16);
    SIFCmdSetSReg:
      ;
    SIFCmdInit:
      if PacketU32(P, 12) = 0 then
        EERecvAddr := PacketU32(P, 16)
      else
      begin
        // RPC initialization: SIF_SREG_RPCINIT = 1 on the EE.
        var R: TBytes;
        SetLength(R, 24);
        SetPacketU32(R, 16, 0);
        SetPacketU32(R, 20, 1);
        SendCommand(SIFCmdSetSReg, R);
      end;
    SIFCmdReset:
      begin
        var Len := Integer(PacketU32(P, 16));
        if Len > 80 then
          Len := 80;
        var Args := '';
        if Len > 0 then
        begin
          var B: TBytes;
          SetLength(B, Len);
          Move((FIOPRAM + Address + 24)^, B[0], Len);
          Args := TEncoding.ANSI.GetString(B).TrimRight([#0]);
        end;
        if Assigned(FOnReset) then
          FOnReset(Args);
      end;
    SIFCmdRPCBind:
      Bind(P);
    SIFCmdRPCCall:
      Call(P);
    SIFCmdRPCRData:
      OtherData(P);
  else
    if Assigned(FOnGuestCommand) then
      FOnGuestCommand(Cid, P);
  end;
end;

procedure TPS2SIF.Bind(const P: TBytes);
begin
  // SifRpcBindPkt: rec_id 16, pkt_addr 20, rpc_id 24, cd 28, sid 32.
  var SID := PacketU32(P, 32);
  var Server := FindServer(SID);
  if (Server = nil) and Assigned(FOnGuestCommand) then
  begin
    FOnGuestCommand(SIFCmdRPCBind, P);
    Exit;
  end;
  if (Server = nil) and StubUnknownServers then
  begin
    // No module provides it: an empty server keeps the EE going.
    Server := TPS2StubServer.Create(SID);
    FStubs.Add(Server);
    AddServer(Server);
    if Log <> nil then
      Log.Add(Format('sif stub server %.8x', [SID]));
  end;
  var R: TBytes;
  SetLength(R, 64);
  SetPacketU32(R, 16, 0);
  SetPacketU32(R, 20, PacketU32(P, 20));
  SetPacketU32(R, 24, PacketU32(P, 24));
  SetPacketU32(R, 28, PacketU32(P, 28));
  SetPacketU32(R, 32, SIFCmdRPCBind);
  if Server <> nil then
  begin
    SetPacketU32(R, 36, SIFIOPServerData + Cardinal(Server.FIndex) * $40);
    SetPacketU32(R, 40, SIFIOPServerBuffers + Cardinal(Server.FIndex) * SIFIOPServerBufferSize);
    SetPacketU32(R, 44, 0);
  end;
  SendCommand(SIFCmdRPCEnd, R);
end;

procedure TPS2SIF.Call(const P: TBytes);
begin
  // SifRpcCallPkt: rec_id 16, pkt_addr 20, rpc_id 24, cd 28, rpc_number 32,
  // send_size 36, recvbuf 40, recv_size 44, rmode 48, sd 52.
  var SD := PacketU32(P, 52);
  var Index := Integer((SD - SIFIOPServerData) div $40);
  if (SD < SIFIOPServerData) or (Index >= FServers.Count) then
  begin
    if Assigned(FOnGuestCommand) then
      FOnGuestCommand(SIFCmdRPCCall, P);
    Exit;
  end;
  var Server := FServers[Index];
  var Buffer := SIFIOPServerBuffers + Cardinal(Index) * SIFIOPServerBufferSize;
  var RecvBuf := PacketU32(P, 40);
  var RecvSize := Integer(PacketU32(P, 44));
  var Reply := Server.Call(PacketU32(P, 32), FIOPRAM + Buffer, Integer(PacketU32(P, 36)), RecvSize);
  if (RecvSize > 0) and (RecvBuf <> 0) then
  begin
    var Data := Copy(Reply, 0, RecvSize);
    if Length(Data) < RecvSize then
      SetLength(Data, RecvSize);
    SendData(RecvBuf, Data);
  end;
  var R: TBytes;
  SetLength(R, 64);
  SetPacketU32(R, 20, PacketU32(P, 20));
  SetPacketU32(R, 28, PacketU32(P, 28));
  SetPacketU32(R, 32, SIFCmdRPCCall);
  if PacketU32(P, 48) <> 0 then
  begin
    SetPacketU32(R, 16, PacketU32(P, 16));
    SetPacketU32(R, 24, PacketU32(P, 24));
    SendCommand(SIFCmdRPCEnd, R);
  end
  else
  begin
    // No end function: the reply frees the EE packet in place.
    SendCommand(SIFCmdRPCEnd, R, True, PacketU32(P, 20));
  end;
end;

procedure TPS2SIF.OtherData(const P: TBytes);
begin
  // SifRpcOtherDataPkt: recvbuf 28, src 32 (IOP), dest 36 (EE), size 40.
  var Src := PacketU32(P, 32) and PS2IOPRAMMask;
  var Size := Integer(PacketU32(P, 40));
  if (Size > 0) and (Src + Cardinal(Size) <= PS2IOPRAMSize) then
  begin
    var Data: TBytes;
    SetLength(Data, Size);
    Move((FIOPRAM + Src)^, Data[0], Size);
    SendData(PacketU32(P, 36), Data);
  end;
  var R: TBytes;
  SetLength(R, 64);
  SetPacketU32(R, 20, PacketU32(P, 20));
  SetPacketU32(R, 24, PacketU32(P, 24));
  SetPacketU32(R, 28, PacketU32(P, 28));
  SetPacketU32(R, 32, SIFCmdRPCRData);
  SendCommand(SIFCmdRPCEnd, R);
end;

procedure TPS2SIF.SerializeState(State: TStateArchive);
begin
  State.Field(MSCOM, SizeOf(MSCOM));
  State.Field(SMCOM, SizeOf(SMCOM));
  State.Field(MSFLG, SizeOf(MSFLG));
  State.Field(SMFLG, SizeOf(SMFLG));
  State.Field(CTRL, SizeOf(CTRL));
  State.Field(BD6, SizeOf(BD6));
  State.Field(EERecvAddr, SizeOf(EERecvAddr));
  var Count := FQueue.Count;
  State.Field(Count, SizeOf(Count));
  if State.Loading then
  begin
    FQueue.Clear;
    for var K := 0 to Count - 1 do
    begin
      var C: TPS2SIFChunk;
      var Len: Integer;
      State.Field(C.Dest, SizeOf(C.Dest));
      State.Field(C.IRQ, SizeOf(C.IRQ));
      State.Field(Len, SizeOf(Len));
      if (Len < 0) or (Len > $1000000) then
        raise EReadError.Create('PS2 snapshot SIF queue');
      SetLength(C.Data, Len);
      if Len > 0 then
        State.Field(C.Data[0], Len);
      FQueue.Add(C);
    end;
  end
  else
    for var C in FQueue do
    begin
      var Dest := C.Dest;
      var IRQ := C.IRQ;
      var Len := Length(C.Data);
      State.Field(Dest, SizeOf(Dest));
      State.Field(IRQ, SizeOf(IRQ));
      State.Field(Len, SizeOf(Len));
      if Len > 0 then
        State.Field(C.Data[0], Len);
    end;
  for var S in FServers do
    S.SerializeState(State);
end;

end.
