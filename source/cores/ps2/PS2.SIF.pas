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
  SIFIOPServerBufferSize = $2000;
  // Servers beyond this share the last buffers (below the IOP heap).
  SIFIOPServerBufferCount = 30;

type
  TPS2SIF = class;

  // A high-level RPC server. Call runs function Fn with the arguments the EE
  // sent (Args, Size bytes in IOP RAM) and returns the reply bytes (at most
  // the EE's receive size).
  TPS2RPCServer = class
  private
    FSID: Cardinal;
    FIndex: Integer;
    FPacket: TBytes;
    FDeferred: Boolean;
  protected
    FSIF: TPS2SIF;
    // From Call: no reply now; Complete answers later with the returned
    // token (the call packet).
    function Defer: TBytes;
  public
    // Reply latency in EE cycles (0: the SIF default).
    Latency: Int64;
    constructor Create(SID: Cardinal);
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; virtual; abstract;
    procedure Reset; virtual;
    procedure SerializeState(State: TStateArchive); virtual;
    procedure Complete(const Token, Reply: TBytes);
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
    // Not delivered before this EE cycle.
    Due: Int64;
  end;

  // RPC bind or call for a server that is not high-level (an IOP module's,
  // through the IOP side): Kind is the command id, Packet the EE packet.
  TPS2SIFGuestCommand = procedure(Kind: Cardinal; const Packet: TBytes) of object;
  // A bind for a SID no high-level server has: True when the IOP side
  // answered (with a server or 'not yet').
  TPS2SIFGuestBind = function(const Packet: TBytes): Boolean of object;
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
    FOnGuestBind: TPS2SIFGuestBind;
    function ServerBuffer(Index: Integer): Cardinal;
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
    function ServerCount: Integer;
    // EE-side registers (SifSetReg/SifGetReg and MMIO 1000F2x0h).
    function ReadRegister(Index: Cardinal): Cardinal;
    procedure WriteRegister(Index, Value: Cardinal);
    // An EE-to-IOP transfer (SifSetDma): Size bytes from EE physical Src to
    // IOP Dest; commands to the IOP command buffer run on arrival.
    procedure EEToIOP(Src, Dest: Cardinal; Size: Integer; Attr: Cardinal);
    // IOP-to-EE: data chunks then a command packet for the EE's buffer.
    procedure SendData(Dest: Cardinal; const Data: TBytes);
    procedure SendCommand(Cid: Cardinal; Packet: TBytes; NoIRQ: Boolean = False; Dest: Cardinal = 0;
      Delay: Int64 = 0);
    // Delivers queued packets while DMAC channel 5 is armed.
    procedure Deliver;
    // Answers an RPC call packet: Reply (up to the EE's receive size) then
    // the end command.
    procedure ReplyCall(const P: TBytes; const Reply: TBytes; Delay: Int64 = 0);
    // Answers a bind packet with the server's IOP addresses (0: not there).
    procedure ReplyBind(const P: TBytes; SD, Buff, CBuff: Cardinal);
    // Drops the made-up server for SID (a module now provides it).
    procedure RemoveStub(SID: Cardinal);
    // A command packet built by the IOP side (header kept but psize).
    procedure SendRawCommand(Packet: TBytes);
    procedure SerializeState(State: TStateArchive);
    property EERAM: PByte read FEERAM;
    // EE RAM written by a high-level IOP service (code caches, diagnostics).
    procedure MarkEE(Address, Size: Cardinal);
    property IOPRAM: PByte read FIOPRAM;
    property OnReset: TPS2SIFReset read FOnReset write FOnReset;
    property OnGuestCommand: TPS2SIFGuestCommand read FOnGuestCommand write FOnGuestCommand;
    property OnGuestBind: TPS2SIFGuestBind read FOnGuestBind write FOnGuestBind;
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

function TPS2RPCServer.Defer: TBytes;
begin
  FDeferred := True;
  Result := Copy(FPacket);
end;

procedure TPS2RPCServer.Complete(const Token, Reply: TBytes);
begin
  if FSIF <> nil then
    FSIF.ReplyCall(Token, Reply, Latency);
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

function TPS2SIF.ServerBuffer(Index: Integer): Cardinal;
begin
  if Index >= SIFIOPServerBufferCount then
    Index := SIFIOPServerBufferCount - 1 - (Index mod 4);
  Result := SIFIOPServerBuffers + Cardinal(Index) * SIFIOPServerBufferSize;
end;

procedure TPS2SIF.RemoveStub(SID: Cardinal);
begin
  for var K := FStubs.Count - 1 downto 0 do
    if FStubs[K].SID = SID then
    begin
      // Keep the indices of later servers: the stub stays as a placeholder
      // with an unused SID.
      FStubs[K].FSID := 0;
    end;
end;

function TPS2SIF.ServerCount: Integer;
begin
  Result := FServers.Count;
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
  C.Due := 0;
  FQueue.Add(C);
end;

procedure TPS2SIF.SendCommand(Cid: Cardinal; Packet: TBytes; NoIRQ: Boolean; Dest: Cardinal; Delay: Int64);
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
  C.Due := FScheduler.Now + Max(ReplyDelay, Delay);
  FQueue.Add(C);
  if not FScheduler.Pending(TPS2Event.SIF) then
    FScheduler.Schedule(TPS2Event.SIF, C.Due);
end;

procedure TPS2SIF.Deliver;
begin
  while FQueue.Count > 0 do
  begin
    var C := FQueue[0];
    if C.Due > FScheduler.Now then
    begin
      FScheduler.Schedule(TPS2Event.SIF, C.Due);
      Exit;
    end;
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
    FScheduler.Schedule(TPS2Event.SIF, Max(FScheduler.Now + ReplyDelay div 4, FQueue[0].Due));
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
  if (Log <> nil) and (Cid <> SIFCmdRPCCall) then
    Log.Add(Format('sif cmd %.8x %.8x', [Cid, PacketU32(P, 32)]));
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
  if (Server = nil) and Assigned(FOnGuestBind) and FOnGuestBind(P) then
    Exit;
  if (Server = nil) and StubUnknownServers then
  begin
    // No module provides it: an empty server keeps the EE going.
    Server := TPS2StubServer.Create(SID);
    FStubs.Add(Server);
    AddServer(Server);
    if Log <> nil then
      Log.Add(Format('sif stub server %.8x', [SID]));
  end;
  if Server <> nil then
    ReplyBind(P, SIFIOPServerData + Cardinal(Server.FIndex) * $40, ServerBuffer(Server.FIndex), 0)
  else
    ReplyBind(P, 0, 0, 0);
end;

procedure TPS2SIF.ReplyBind(const P: TBytes; SD, Buff, CBuff: Cardinal);
begin
  var R: TBytes;
  SetLength(R, 64);
  SetPacketU32(R, 16, 0);
  SetPacketU32(R, 20, PacketU32(P, 20));
  SetPacketU32(R, 24, PacketU32(P, 24));
  SetPacketU32(R, 28, PacketU32(P, 28));
  SetPacketU32(R, 32, SIFCmdRPCBind);
  SetPacketU32(R, 36, SD);
  SetPacketU32(R, 40, Buff);
  SetPacketU32(R, 44, CBuff);
  SendCommand(SIFCmdRPCEnd, R);
end;

procedure TPS2SIF.SendRawCommand(Packet: TBytes);
begin
  if Length(Packet) < 16 then
    SetLength(Packet, 16);
  var Len := Length(Packet);
  PCardinal(@Packet[0])^ := (PCardinal(@Packet[0])^ and not $FF) or (Cardinal(Len) and $FF);
  var C: TPS2SIFChunk;
  C.Dest := EERecvAddr;
  C.Data := Packet;
  C.IRQ := True;
  C.Due := FScheduler.Now + ReplyDelay;
  FQueue.Add(C);
  if not FScheduler.Pending(TPS2Event.SIF) then
    FScheduler.Schedule(TPS2Event.SIF, C.Due);
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
  if Log <> nil then
    Log.Add(Format('sif call %.8x fn %x size %d/%d', [Server.SID, PacketU32(P, 32), PacketU32(P, 36),
      PacketU32(P, 44)]));
  var Buffer := ServerBuffer(Index);
  Server.FPacket := P;
  Server.FDeferred := False;
  var Reply := Server.Call(PacketU32(P, 32), FIOPRAM + Buffer, Integer(PacketU32(P, 36)),
    Integer(PacketU32(P, 44)));
  Server.FPacket := nil;
  if not Server.FDeferred then
    ReplyCall(P, Reply, Server.Latency);
end;

procedure TPS2SIF.ReplyCall(const P: TBytes; const Reply: TBytes; Delay: Int64);
begin
  var RecvBuf := PacketU32(P, 40);
  var RecvSize := Integer(PacketU32(P, 44));
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
    SendCommand(SIFCmdRPCEnd, R, False, 0, Delay);
  end
  else
  begin
    // No end function: the reply frees the EE packet in place.
    SendCommand(SIFCmdRPCEnd, R, True, PacketU32(P, 20), Delay);
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
      State.Field(C.Due, SizeOf(C.Due));
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
      var Due := C.Due;
      var Len := Length(C.Data);
      State.Field(Dest, SizeOf(Dest));
      State.Field(IRQ, SizeOf(IRQ));
      State.Field(Due, SizeOf(Due));
      State.Field(Len, SizeOf(Len));
      if Len > 0 then
        State.Field(C.Data[0], Len);
    end;
  // Servers made up for unknown SIDs, in binding order.
  var StubCount := FStubs.Count;
  State.Field(StubCount, SizeOf(StubCount));
  if State.Loading then
  begin
    if (StubCount < 0) or (StubCount > 1024) then
      raise EReadError.Create('PS2 snapshot SIF servers');
    for var S in FStubs do
      FServers.Remove(S);
    FStubs.Clear;
    for var K := 0 to StubCount - 1 do
    begin
      var SID: Cardinal;
      State.Field(SID, SizeOf(SID));
      var Server := TPS2StubServer.Create(SID);
      FStubs.Add(Server);
      AddServer(Server);
    end;
  end
  else
    for var S in FStubs do
    begin
      var SID := S.SID;
      State.Field(SID, SizeOf(SID));
    end;
  for var S in FServers do
    S.SerializeState(State);
end;

procedure TPS2SIF.MarkEE(Address, Size: Cardinal);
begin
  if FDMAC <> nil then
    FDMAC.MarkWritten(Address, Size);
end;

end.
