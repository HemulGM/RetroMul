unit PSP.Mpeg;

// sceMpeg / sceMpegbase / sceVideocodec: PSMF streams, H.264 video and its audio.
// The guest owns the ring buffer of 2048-byte packs and fills it through its
// callback; the library demuxes packs on demand, keeps what the Media Engine
// would have taken (the ES buffers) and frees a pack once every byte it
// carried for a registered stream was taken.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service, PSP.MpegDemux, PSP.MpegVideo,
  Audio.ATRAC3Plus, PSP.State.Action;

const
  ERROR_MPEG_NO_DATA = Cardinal($80618001);
  ERROR_MPEG_ALREADY_USED = Cardinal($80618005);
  ERROR_MPEG_INVALID_CONTEXT = Cardinal($80618008);
  ERROR_MPEG_NOT_YET_INIT = Cardinal($80618009);
  ERROR_MPEG_INVALID_VALUE = Cardinal($806101FE);
  ERROR_MPEG_INVALID_ADDR = Cardinal($80610103);
  ERROR_MPEG_NO_MEMORY = Cardinal($80610022);
  ERROR_MPEG_AVC_INVALID_VALUE = Cardinal($806201FE);
  ERROR_MPEG_AVC_DECODE_FATAL = Cardinal($80628002);
  ERROR_MPEG_ATRAC_NO_DATA = Cardinal($807F00FD);

  MpegRingPacketCost = 2048 + 104;
  MpegStreamBase = $12C0;
  MpegStreamStride = $440;
  MpegCtxOffset = $B300;

type
  TPSPMpegStreamReg = class
    Address: Cardinal;
    Kind, Number: Integer;
    Queue: TPSPEsQueue;
  end;

  TPSPMpegEsBuf = record
    Used: Boolean;
    Data: TBytes;
    Pts, Dts: Int64;
  end;

  TPSPMpegInstance = class
  public
    Handle, HandlePtr: Cardinal;
    Data, Size: Cardinal;
    Ring: Cardinal;
    FrameWidth: Integer;
    Mode: Integer;
    PixelFormat: Integer;
    Header: TPSPPsmfHeader;
    Demux: TPSPPsDemux;
    Streams: TObjectList<TPSPMpegStreamReg>;
    Avc: TPSPAvc;
    Atrac: TATRAC3PlusDecoder;
    EsBufs: array[1..2] of TPSPMpegEsBuf;
    RingRead: Integer;
    Pictures: Integer;
    LastPicture: TPSPPicture;
    HasDetail: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TPSPMpeg = class(TPSPService)
  private
    FInstances: TObjectList<TPSPMpegInstance>;
    FInit: Boolean;
    FCscWidth: Integer;
    FCscMode: Integer;
    FEsBuf, FDecTop: Cardinal;
    function InstanceAt(Handle: Cardinal): TPSPMpegInstance;
    function InstanceOf(MpegPtr: Cardinal): TPSPMpegInstance;
    function StreamAt(Inst: TPSPMpegInstance; Address: Cardinal): TPSPMpegStreamReg;
    procedure Delay(Us: Int64; Value: Cardinal);
    procedure WriteHeader(Inst: TPSPMpegInstance);
    procedure WriteCodecContext(Inst: TPSPMpegInstance);
    procedure UpdateCodecContext(Inst: TPSPMpegInstance; AuSize: Cardinal; const Pictures: TArray<TPSPPicture>);
    procedure FreePackets(Inst: TPSPMpegInstance);
    function FillQueue(Inst: TPSPMpegInstance; Q: TPSPEsQueue): Boolean;
    procedure WriteAu(Address: Cardinal; const Au: TPSPAccessUnit; EsBuffer: Cardinal; WriteEs: Boolean);
    procedure PutStep(Rb, Remaining, Done: Cardinal);
    procedure StateRingRead(Action: TPSPStateAction; Value: Cardinal);
    function DecodeAu(Inst: TPSPMpegInstance; AuPtr: Cardinal; out Pictures: TArray<TPSPPicture>): Cardinal;
    procedure InitYCbCr(Buf: Cardinal; W, H: Integer);
    procedure WriteYCbCr(const Pic: TPSPPicture; Buf: Cardinal);
    procedure WritePictureTo(Inst: TPSPMpegInstance; const Pic: TPSPPicture; Buffer: Cardinal; Width: Integer);
    function MePlanes(Addr: Cardinal; MbW, MbH: Integer; out Planes: TPSPMePlanes): Boolean;
    procedure TouchPlanes(Addr: Cardinal; MbW, MbH: Integer);
    procedure CscAvc(Out_, Second: Cardinal; Stride: Integer; Desc: Cardinal; X0, Y0, W, H, Format: Integer;
      Ranged: Boolean);
    procedure hInit;
    procedure hFinish;
    procedure hQueryMemSize;
    procedure hCreate;
    procedure hDelete;
    procedure hRingbufferQueryMemSize;
    procedure hRingbufferQueryPackNum;
    procedure hRingbufferConstruct;
    procedure hRingbufferDestruct;
    procedure hRingbufferPut;
    procedure hRingbufferAvailableSize;
    procedure hQueryStreamOffset;
    procedure hQueryStreamSize;
    procedure hRegistStream;
    procedure hUnRegistStream;
    procedure hFlushStream;
    procedure hFlushAllStream;
    procedure hMallocAvcEsBuf;
    procedure hFreeAvcEsBuf;
    procedure hQueryAtracEsSize;
    procedure hQueryPcmEsSize;
    procedure hInitAu;
    procedure hGetAvcAu;
    procedure hGetAtracAu;
    procedure hGetPcmAu;
    procedure hChangeGetAuMode;
    procedure hChangeGetAvcAuMode;
    procedure hAvcDecode;
    procedure hAvcDecodeStop;
    procedure hAvcDecodeFlush;
    procedure hAvcDecodeMode;
    procedure hAvcDecodeDetail;
    procedure hAvcQueryYCbCrSize;
    procedure hAvcInitYCbCr;
    procedure hAvcDecodeYCbCr;
    procedure hAvcDecodeStopYCbCr;
    procedure hAvcCsc;
    procedure hAtracDecode;
    procedure hAvcResourceInit;
    procedure hAvcResourceFinish;
    procedure hAvcResourceGetAvcDecTopAddr;
    procedure hAvcResourceGetAvcEsBuf;
    procedure hZero;
    procedure hBaseCscInit;
    procedure hBaseYCrCbCopyVme;
    procedure hBaseCscVme;
    procedure hBaseCscAvc;
    procedure hBaseCscAvcRange;
    procedure hBaseCscMode;
    procedure hVideocodecGetSEI;
    procedure hBasePESpacketCopy;
    procedure hAvcConvertToYuv420;
    procedure hAvcCopyYCbCr;
    procedure hBaseYCrCbCopy;
    procedure hAvcDecodeDetail2;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    property Instances: TObjectList<TPSPMpegInstance> read FInstances;
  end;

implementation

uses
  System.Math, PSP.Mp4, PSP.Videocodec;

const
  LibMpeg = 'sceMpeg';
  LibBase = 'sceMpegbase';
  LibCodec = 'sceVideocodec';

{ TPSPMpegInstance }

constructor TPSPMpegInstance.Create;
begin
  inherited Create;
  Demux := TPSPPsDemux.Create;
  Streams := TObjectList<TPSPMpegStreamReg>.Create(True);
  Avc := TPSPAvc.Create;
  PixelFormat := PSPPixel8888;
end;

destructor TPSPMpegInstance.Destroy;
begin
  Atrac.Free;
  Avc.Free;
  Streams.Free;
  Demux.Free;
  inherited;
end;

{ TPSPMpeg }

constructor TPSPMpeg.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FInstances := TObjectList<TPSPMpegInstance>.Create(True);
end;

destructor TPSPMpeg.Destroy;
begin
  FInstances.Free;
  inherited;
end;

procedure TPSPMpeg.Reset;
begin
  FInstances.Clear;
  FInit := False;
  FCscWidth := 512;
  FCscMode := 0;
end;

procedure TPSPMpeg.Register;
begin
  var H := FHLE;
  H.Register(LibMpeg, $682A619B, 'sceMpegInit', hInit);
  H.Register(LibMpeg, $874624D6, 'sceMpegFinish', hFinish);
  H.Register(LibMpeg, $C132E22F, 'sceMpegQueryMemSize', hQueryMemSize);
  H.Register(LibMpeg, $D8C5F121, 'sceMpegCreate', hCreate);
  H.Register(LibMpeg, $606A4649, 'sceMpegDelete', hDelete);
  H.Register(LibMpeg, $D7A29F46, 'sceMpegRingbufferQueryMemSize', hRingbufferQueryMemSize);
  H.Register(LibMpeg, $769BEBB6, 'sceMpegRingbufferQueryPackNum', hRingbufferQueryPackNum);
  H.Register(LibMpeg, $37295ED8, 'sceMpegRingbufferConstruct', hRingbufferConstruct);
  H.Register(LibMpeg, $13407F13, 'sceMpegRingbufferDestruct', hRingbufferDestruct);
  H.Register(LibMpeg, $B240A59E, 'sceMpegRingbufferPut', hRingbufferPut);
  H.Register(LibMpeg, $B5F6DC87, 'sceMpegRingbufferAvailableSize', hRingbufferAvailableSize);
  H.Register(LibMpeg, $21FF80E4, 'sceMpegQueryStreamOffset', hQueryStreamOffset);
  H.Register(LibMpeg, $611E9E11, 'sceMpegQueryStreamSize', hQueryStreamSize);
  H.Register(LibMpeg, $42560F23, 'sceMpegRegistStream', hRegistStream);
  H.Register(LibMpeg, $591A4AA2, 'sceMpegUnRegistStream', hUnRegistStream);
  H.Register(LibMpeg, $500F0429, 'sceMpegFlushStream', hFlushStream);
  H.Register(LibMpeg, $707B7629, 'sceMpegFlushAllStream', hFlushAllStream);
  H.Register(LibMpeg, $A780CF7E, 'sceMpegMallocAvcEsBuf', hMallocAvcEsBuf);
  H.Register(LibMpeg, $CEB870B1, 'sceMpegFreeAvcEsBuf', hFreeAvcEsBuf);
  H.Register(LibMpeg, $F8DCB679, 'sceMpegQueryAtracEsSize', hQueryAtracEsSize);
  H.Register(LibMpeg, $C02CF6B5, 'sceMpegQueryPcmEsSize', hQueryPcmEsSize);
  H.Register(LibMpeg, $167AFD9E, 'sceMpegInitAu', hInitAu);
  H.Register(LibMpeg, $FE246728, 'sceMpegGetAvcAu', hGetAvcAu);
  H.Register(LibMpeg, $E1CE83A7, 'sceMpegGetAtracAu', hGetAtracAu);
  H.Register(LibMpeg, $8C1E027D, 'sceMpegGetPcmAu', hGetPcmAu);
  H.Register(LibMpeg, $9DCFB7EA, 'sceMpegChangeGetAuMode', hChangeGetAuMode);
  H.Register(LibMpeg, $234586AE, 'sceMpegChangeGetAvcAuMode', hChangeGetAvcAuMode);
  H.Register(LibMpeg, $0E3C2E9D, 'sceMpegAvcDecode', hAvcDecode);
  H.Register(LibMpeg, $740FCCD1, 'sceMpegAvcDecodeStop', hAvcDecodeStop);
  H.Register(LibMpeg, $4571CC64, 'sceMpegAvcDecodeFlush', hAvcDecodeFlush);
  H.Register(LibMpeg, $A11C7026, 'sceMpegAvcDecodeMode', hAvcDecodeMode);
  H.Register(LibMpeg, $0F6C18D7, 'sceMpegAvcDecodeDetail', hAvcDecodeDetail);
  H.Register(LibMpeg, $211A057C, 'sceMpegAvcQueryYCbCrSize', hAvcQueryYCbCrSize);
  H.Register(LibMpeg, $67179B1B, 'sceMpegAvcInitYCbCr', hAvcInitYCbCr);
  H.Register(LibMpeg, $F0EB1125, 'sceMpegAvcDecodeYCbCr', hAvcDecodeYCbCr);
  H.Register(LibMpeg, $F2930C9C, 'sceMpegAvcDecodeStopYCbCr', hAvcDecodeStopYCbCr);
  H.Register(LibMpeg, $31BD0272, 'sceMpegAvcCsc', hAvcCsc);
  H.Register(LibMpeg, $800C44DF, 'sceMpegAtracDecode', hAtracDecode);
  H.Register(LibMpeg, $FCBDB5AD, 'sceMpegAvcResourceInit', hAvcResourceInit);
  H.Register(LibMpeg, $8160A2FE, 'sceMpegAvcResourceFinish', hAvcResourceFinish);
  H.Register(LibMpeg, $63B9536A, 'sceMpegAvcResourceGetAvcDecTopAddr', hAvcResourceGetAvcDecTopAddr);
  H.Register(LibMpeg, $AF26BB01, 'sceMpegAvcResourceGetAvcEsBuf', hAvcResourceGetAvcEsBuf);
  H.Register(LibMpeg, $C45C99CC, 'sceMpegQueryUserdataEsSize', hZero);
  H.Register(LibMpeg, $01977054, 'sceMpegGetUserdataAu', hZero);
  H.Register(LibBase, $492B5E4B, 'sceMpegBaseCscInit', hBaseCscInit);
  H.Register(LibBase, $BE45C284, 'sceMpegBaseYCrCbCopyVme', hBaseYCrCbCopyVme);
  H.Register(LibBase, $CE8EB837, 'sceMpegBaseCscVme', hBaseCscVme);
  H.Register(LibBase, $91929A21, 'sceMpegBaseCscAvc', hBaseCscAvc);
  H.Register(LibBase, $304882E1, 'sceMpegBaseCscAvcRange', hBaseCscAvcRange);
  H.Register(LibBase, $0530BE4E, 'sceMpegbase_0530BE4E', hBaseCscMode);
  H.Register(LibBase, $BEA18F91, 'sceMpegBasePESpacketCopy', hBasePESpacketCopy);
  H.Register(LibMpeg, $CF3547A2, 'sceMpegAvcDecodeDetail2', hAvcDecodeDetail2);
  H.Register(LibMpeg, $F5E7EA31, 'sceMpegAvcConvertToYuv420', hAvcConvertToYuv420);
  H.Register(LibMpeg, $0558B075, 'sceMpegAvcCopyYCbCr', hAvcCopyYCbCr);
  H.Register(LibBase, $7AC0321A, 'sceMpegBaseYCrCbCopy', hBaseYCrCbCopy);
  H.Register(LibCodec, $627B7D42, 'sceVideocodecGetSEI', hVideocodecGetSEI);
end;

function TPSPMpeg.InstanceAt(Handle: Cardinal): TPSPMpegInstance;
begin
  for var I in FInstances do
    if (I.Handle and $3FFFFFFF) = (Handle and $3FFFFFFF) then
      Exit(I);
  Result := nil;
end;

function TPSPMpeg.InstanceOf(MpegPtr: Cardinal): TPSPMpegInstance;
begin
  if (MpegPtr = 0) or not FMemory.Valid(MpegPtr, 4) then
    Exit(nil);
  Result := InstanceAt(FMemory.Read32(MpegPtr));
end;

function TPSPMpeg.StreamAt(Inst: TPSPMpegInstance; Address: Cardinal): TPSPMpegStreamReg;
begin
  for var S in Inst.Streams do
    if S.Address = Address then
      Exit(S);
  Result := nil;
end;

procedure TPSPMpeg.Delay(Us: Int64; Value: Cardinal);
begin
  FHLE.Result(Value);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'mpeg');
  if T.Wait.HLETag <> 'mpeg' then
    Exit;
  T.Wait.Data[0] := Value;
  FKernel.AddWakeTimer(FKernel.Scheduler.Now + Us * 1000, T, 'mpeg', Value, 0);
end;

procedure TPSPMpeg.WriteHeader(Inst: TPSPMpegInstance);
begin
  var H := Inst.Handle;
  FMemory.WriteString(H, 'LIBMPEG', 8);
  FMemory.WriteString(H + 8, '001', 4);
  FMemory.Write32(H + 12, $FFFFFFFF);
  FMemory.Write32(H + 16, Inst.Ring);
  if Inst.Ring <> 0 then
    FMemory.Write32(H + 20, FMemory.Read32(Inst.Ring + $20))
  else
    FMemory.Write32(H + 20, 0);
  FMemory.Write32(H + 24, H + $740);
  FMemory.Write32(H + 28, H + $740 + $740);
  FMemory.Write32(H + 32, H + $740 + $740 + $1E00);
  FMemory.Write32(H + 36, 0);
  FMemory.Write32(H + 40, 99);
end;

const
  // The context the ME keeps in the mpeg buffer, and its stream parameters (ctx+180).
  CodecHead: array[0..18] of Cardinal = ($05100601, $78, 0, $001B3140, 0, $001B3140, $3C2C, $09000000,
    $15C00, $4A000, 0, 0, 0, 0, 0, 4, 480, 272, 2);
  CodecParams: array[0..24] of Cardinal = ($101, 0, 0, $05010001, 1, $10000, 0, 0, $FA4, $3A980, $10101, 1,
    0, 0, 0, 0, 0, 0, $18060611, $60400, $270, $270, $60400, $270, $270);

procedure TPSPMpeg.WriteCodecContext(Inst: TPSPMpegInstance);
begin
  // The sceVideocodec context the ME works with, kept in the mpeg buffer.
  var Ctx := Inst.Data + MpegCtxOffset + $30;
  if Ctx + $200 > Inst.Data + Inst.Size then
    Exit;
  FMemory.Write32(Inst.Handle + $6C0, Ctx);
  FMemory.Fill(Ctx, 0, $200);
  for var I := 0 to High(CodecHead) do
    FMemory.Write32(Ctx + Cardinal(I) * 4, CodecHead[I]);
  FMemory.Write32(Ctx + $10, Ctx + $80);
  FMemory.Write32(Ctx + $2C, Ctx + $C0);
  FMemory.Write32(Ctx + $30, Ctx + $180);
  for var I := 0 to High(CodecParams) do
    FMemory.Write32(Ctx + $180 + Cardinal(I) * 4, CodecParams[I]);
end;

procedure TPSPMpeg.UpdateCodecContext(Inst: TPSPMpegInstance; AuSize: Cardinal; const Pictures: TArray<TPSPPicture>);
begin
  // What the ME leaves in its context after a decode: the unit's size, four
  // picture descriptors (0x2C bytes) and, when the caller gave a buffer at
  // ctx+38, each descriptor's SEI records.
  var Ctx := FMemory.Read32(Inst.Handle + $6C0);
  if (Ctx = 0) or not FMemory.Valid(Ctx, $200) then
    Exit;
  FMemory.Write32(Ctx + $28, AuSize);
  var Records := FMemory.Read32(Ctx + $38);
  for var I := 0 to 3 do
  begin
    var Desc := Ctx + $C0 + Cardinal(I) * $2C;
    if Records <> 0 then
    begin
      FMemory.Write32(Desc + $24, Records + Cardinal(I) * $148);
      FMemory.Write32(Desc + $28, Records + Cardinal(I) * $148 + $A4);
    end
    else
    begin
      FMemory.Write32(Desc + $24, 0);
      FMemory.Write32(Desc + $28, 0);
    end;
  end;
  if Length(Pictures) = 0 then
    Exit;
  FMemory.Write32(Ctx + $C0 + $20, Ord(Pictures[0].Idr));
  if (Records <> 0) and FMemory.Valid(Records, $148) then
  begin
    FMemory.Fill(Records, 0, $148);
    var R := Pictures[0].Record_;
    if Length(R) > 0 then
      FMemory.WriteBytes(Records, R[0], Length(R) * 4);
  end;
end;

{ Basics }

procedure TPSPMpeg.hInit;
begin
  FInit := True;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hFinish;
begin
  FInit := False;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hQueryMemSize;
begin
  FHLE.Result($10000);
end;

procedure TPSPMpeg.hCreate;
begin
  if not FKernel.CanWait then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_CONTEXT);
    Exit;
  end;
  var MpegPtr := FHLE.Arg(0);
  var Data := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  var Ring := FHLE.Arg(3);
  var FrameWidth := FHLE.ArgInt(4);
  var Mode := FHLE.ArgInt(5);
  if Size < $10000 then
  begin
    FHLE.Result(ERROR_MPEG_NO_MEMORY);
    Exit;
  end;
  if (MpegPtr = 0) or (Data = 0) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_ADDR);
    Exit;
  end;
  var Inst := TPSPMpegInstance.Create;
  Inst.HandlePtr := MpegPtr;
  Inst.Data := Data;
  Inst.Size := Size;
  Inst.Handle := AlignUp(Data, 64);
  Inst.Ring := Ring;
  Inst.FrameWidth := FrameWidth;
  Inst.Mode := Mode;
  FInstances.Add(Inst);
  FMemory.Fill(Data, 0, Min(Size, Cardinal($10000)));
  WriteHeader(Inst);
  WriteCodecContext(Inst);
  FMemory.Write32(MpegPtr, Inst.Handle);
  if Ring <> 0 then
    FMemory.Write32(Ring + $28, MpegPtr);
  Delay(1000, 0);
end;

procedure TPSPMpeg.hDelete;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  FInstances.Remove(Inst);
  Delay(30000, 0);
end;

{ Ring buffer }

procedure TPSPMpeg.hRingbufferQueryMemSize;
begin
  FHLE.Result(Cardinal(Int64(FHLE.ArgInt(0)) * MpegRingPacketCost));
end;

procedure TPSPMpeg.hRingbufferQueryPackNum;
begin
  FHLE.Result(FHLE.Arg(0) div MpegRingPacketCost);
end;

procedure TPSPMpeg.hRingbufferConstruct;
begin
  var Rb := FHLE.Arg(0);
  var Packets := FHLE.ArgInt(1);
  var Data := FHLE.Arg(2);
  var Size := FHLE.ArgInt(3);
  var Callback := FHLE.Arg(4);
  var CbArg := FHLE.Arg(5);
  // A 32-bit product, as the library computes it.
  if Size < Integer(Cardinal(Int64(Packets) * MpegRingPacketCost)) then
  begin
    FHLE.Result(ERROR_MPEG_NO_MEMORY);
    Exit;
  end;
  FMemory.Write32(Rb + $00, Cardinal(Packets));
  FMemory.Write32(Rb + $04, 0);
  FMemory.Write32(Rb + $08, 0);
  FMemory.Write32(Rb + $0C, 0);
  FMemory.Write32(Rb + $10, PSMFPacketSize);
  FMemory.Write32(Rb + $14, Data);
  FMemory.Write32(Rb + $18, Callback);
  FMemory.Write32(Rb + $1C, CbArg);
  FMemory.Write32(Rb + $20, Cardinal(Int64(Data) + Int64(Cardinal(Packets)) * PSMFPacketSize));
  FMemory.Write32(Rb + $24, 0);
  FMemory.Write32(Rb + $28, 0);
  FMemory.Write32(Rb + $2C, FHLE.CPU.Ctx.GPR[28]);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hRingbufferDestruct;
begin
  FHLE.Result(0);
end;

procedure TPSPMpeg.PutStep(Rb, Remaining, Done: Cardinal);
begin
  var Total := Integer(FMemory.Read32(Rb));
  var Write := Integer(FMemory.Read32(Rb + 8));
  var Callback := FMemory.Read32(Rb + $18);
  if (Remaining = 0) or (Callback = 0) or (Total <= 0) then
  begin
    FHLE.CPU.Ctx.GPR[2] := Done;
    Exit;
  end;
  if (Write < 0) or (Write >= Total) then
    Write := 0;
  var Chunk := Min(Integer(Remaining), Total - Write);
  var Data := Cardinal(Int64(FMemory.Read32(Rb + $14)) + Int64(Write) * PSMFPacketSize);
  var Arg := FMemory.Read32(Rb + $1C);
  var GP := FMemory.Read32(Rb + $2C);
  FKernel.CallGuest(Callback, [Data, Cardinal(Chunk), Arg], nil, GP, TPSPStateAction.Create(StateRingRead, [],
    [Rb, Remaining, Done, Write, Total, Chunk]));
end;

procedure TPSPMpeg.StateRingRead(Action: TPSPStateAction; Value: Cardinal);
begin
  var R := Integer(Value);
  if R < 0 then
  begin
    FHLE.CPU.Ctx.GPR[2] := Value;
    Exit;
  end;
  var Done := Cardinal(Action.Arg(2));
  if R = 0 then
  begin
    FHLE.CPU.Ctx.GPR[2] := Done;
    Exit;
  end;
  R := Min(R, Integer(Action.Arg(5)));
  var Rb := Cardinal(Action.Arg(0));
  var W := (Integer(Action.Arg(3)) + R) mod Integer(Action.Arg(4));
  FMemory.Write32(Rb + 8, Cardinal(W));
  FMemory.Write32(Rb + $0C, Cardinal(Int64(FMemory.Read32(Rb + $0C)) + R));
  PutStep(Rb, Cardinal(Action.Arg(1)) - Cardinal(R), Done + Cardinal(R));
end;

procedure TPSPMpeg.hRingbufferPut;
begin
  var Rb := FHLE.Arg(0);
  var Num := FHLE.ArgInt(1);
  var Avail := FHLE.ArgInt(2);
  if Num < 0 then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  FHLE.Result(0);
  if Num = 0 then
    Exit;
  var Total := Integer(FMemory.Read32(Rb));
  var Free := Total - Integer(FMemory.Read32(Rb + $0C));
  if Num > Free then
    Num := Free;
  if (Avail >= 0) and (Num > Avail) then
    Num := Avail;
  if Num <= 0 then
    Exit;
  if FKernel.Current = nil then
    Exit;
  PutStep(Rb, Cardinal(Num), 0);
end;

procedure TPSPMpeg.hRingbufferAvailableSize;
begin
  var Rb := FHLE.Arg(0);
  var Inst := InstanceOf(FMemory.Read32(Rb + $28));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  FreePackets(Inst);
  FHLE.Result(FMemory.Read32(Rb) - FMemory.Read32(Rb + $0C));
end;

{ Streams }

procedure TPSPMpeg.hQueryStreamOffset;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var Buffer := FHLE.Arg(1);
  var OffsetPtr := FHLE.Arg(2);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var Head: TBytes;
  SetLength(Head, PSMFPacketSize);
  FMemory.ReadBytes(Buffer, Head[0], PSMFPacketSize);
  var Err := Inst.Header.Parse(Head);
  if Err <> 0 then
  begin
    FMemory.Write32(OffsetPtr, 0);
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  FMemory.Write32(OffsetPtr, Inst.Header.HeaderSize);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hQueryStreamSize;
begin
  var Buffer := FHLE.Arg(0);
  var SizePtr := FHLE.Arg(1);
  if FMemory.Read32(Buffer) <> $464D5350 then
  begin
    FMemory.Write32(SizePtr, 0);
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var B: array[0..3] of Byte;
  FMemory.ReadBytes(Buffer + 12, B, 4);
  var Size := PSMFBE32(@B[0]);
  if (Size and $7FF) <> 0 then
  begin
    FMemory.Write32(SizePtr, 0);
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  FMemory.Write32(SizePtr, Size);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hRegistStream;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var Kind := FHLE.ArgInt(1);
  var Num := FHLE.ArgInt(2);
  if Inst = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var S := TPSPMpegStreamReg.Create;
  S.Kind := Kind;
  S.Number := Num;
  S.Address := Inst.Handle + MpegStreamBase + Cardinal(Inst.Streams.Count) * MpegStreamStride;
  case Kind of
    PSMFKindAvc:
      S.Queue := Inst.Demux.AddStream(PSMFKindAvc, $E0 + Byte(Num and 15), 0);
    PSMFKindAtrac:
      S.Queue := Inst.Demux.AddStream(PSMFKindAtrac, $BD, Byte(Num and 15));
    PSMFKindPcm:
      S.Queue := Inst.Demux.AddStream(PSMFKindPcm, $BD, $40 + Byte(Num and 15));
  end;
  Inst.Streams.Add(S);
  FHLE.Result(S.Address);
end;

procedure TPSPMpeg.hUnRegistStream;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var S := StreamAt(Inst, FHLE.Arg(1));
  if S = nil then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  if S.Queue <> nil then
    Inst.Demux.RemoveStream(S.Queue);
  Inst.Streams.Remove(S);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hFlushStream;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var S := StreamAt(Inst, FHLE.Arg(1));
  if (S <> nil) and (S.Queue <> nil) then
    S.Queue.Discard;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hFlushAllStream;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  Inst.Demux.Reset;
  Inst.RingRead := 0;
  if Inst.Ring <> 0 then
  begin
    FMemory.Write32(Inst.Ring + 4, 0);
    FMemory.Write32(Inst.Ring + 8, 0);
    FMemory.Write32(Inst.Ring + $0C, 0);
  end;
  for var I := Low(Inst.EsBufs) to High(Inst.EsBufs) do
    Inst.EsBufs[I].Data := nil;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hMallocAvcEsBuf;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  for var I := Low(Inst.EsBufs) to High(Inst.EsBufs) do
    if not Inst.EsBufs[I].Used then
    begin
      Inst.EsBufs[I].Used := True;
      Inst.EsBufs[I].Data := nil;
      FHLE.Result(Cardinal(I));
      Exit;
    end;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hFreeAvcEsBuf;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var B := FHLE.ArgInt(1);
  if (B >= Low(Inst.EsBufs)) and (B <= High(Inst.EsBufs)) then
  begin
    Inst.EsBufs[B].Used := False;
    Inst.EsBufs[B].Data := nil;
  end;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hQueryAtracEsSize;
begin
  var EsPtr := FHLE.Arg(1);
  var OutPtr := FHLE.Arg(2);
  if EsPtr <> 0 then
    FMemory.Write32(EsPtr, $840);
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, $2000);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hQueryPcmEsSize;
begin
  var EsPtr := FHLE.Arg(1);
  var OutPtr := FHLE.Arg(2);
  if EsPtr <> 0 then
    FMemory.Write32(EsPtr, $140);
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, $140);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hInitAu;
begin
  var Au := FHLE.Arg(2);
  FMemory.Write32(Au + 0, 0);
  FMemory.Write32(Au + 4, 0);
  FMemory.Write32(Au + 8, 0);
  FMemory.Write32(Au + 12, 0);
  FMemory.Write32(Au + 16, FHLE.Arg(1));
  FMemory.Write32(Au + 20, 0);
  FHLE.Result(0);
end;

procedure TPSPMpeg.FreePackets(Inst: TPSPMpegInstance);
begin
  var N := Inst.Demux.TakeFreed;
  if (N = 0) or (Inst.Ring = 0) then
    Exit;
  var Rb := Inst.Ring;
  var Total := Integer(FMemory.Read32(Rb));
  var Filled := Integer(FMemory.Read32(Rb + $0C));
  Dec(Filled, N);
  if Filled < 0 then
    Filled := 0;
  FMemory.Write32(Rb + $0C, Cardinal(Filled));
  if Total > 0 then
    Inst.RingRead := (Inst.RingRead + N) mod Total;
  FMemory.Write32(Rb + 4, Cardinal(Inst.RingRead));
end;

function TPSPMpeg.FillQueue(Inst: TPSPMpegInstance; Q: TPSPEsQueue): Boolean;
begin
  // Parses packs from the ring until Q holds a whole access unit.
  Result := Inst.Demux.HasAu(Q);
  if Result or (Inst.Ring = 0) then
    Exit;
  var Rb := Inst.Ring;
  var Total := Integer(FMemory.Read32(Rb));
  if Total <= 0 then
    Exit;
  var Base := FMemory.Read32(Rb + $14);
  var Pack: array[0..PSMFPacketSize - 1] of Byte;
  while not Result do
  begin
    var Filled := Integer(FMemory.Read32(Rb + $0C));
    var Held := Inst.Demux.Held;
    if Held >= Filled then
      Break;
    var Index := (Inst.RingRead + Held) mod Total;
    FMemory.ReadBytes(Cardinal(Int64(Base) + Int64(Index) * PSMFPacketSize), Pack[0], PSMFPacketSize);
    Inst.Demux.FeedPack(@Pack[0]);
    Result := Inst.Demux.HasAu(Q);
  end;
end;

procedure TPSPMpeg.WriteAu(Address: Cardinal; const Au: TPSPAccessUnit; EsBuffer: Cardinal; WriteEs: Boolean);
begin
  if Au.Pts = PSMFNoTimestamp then
  begin
    FMemory.Write32(Address + 0, $FFFFFFFF);
    FMemory.Write32(Address + 4, $FFFFFFFF);
  end
  else
  begin
    FMemory.Write32(Address + 0, Cardinal(Au.Pts shr 32));
    FMemory.Write32(Address + 4, Cardinal(Au.Pts));
  end;
  if Au.Dts = PSMFNoTimestamp then
  begin
    FMemory.Write32(Address + 8, $FFFFFFFF);
    FMemory.Write32(Address + 12, $FFFFFFFF);
  end
  else
  begin
    FMemory.Write32(Address + 8, Cardinal(Au.Dts shr 32));
    FMemory.Write32(Address + 12, Cardinal(Au.Dts));
  end;
  FMemory.Write32(Address + 20, Cardinal(Length(Au.Data)));
end;

procedure TPSPMpeg.hGetAvcAu;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var AuPtr := FHLE.Arg(2);
  var AttrPtr := FHLE.Arg(3);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var S := StreamAt(Inst, FHLE.Arg(1));
  if (S = nil) or (S.Queue = nil) or (S.Kind <> PSMFKindAvc) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  if not FillQueue(Inst, S.Queue) then
  begin
    FHLE.Result(ERROR_MPEG_NO_DATA);
    Exit;
  end;
  var Au: TPSPAccessUnit;
  Inst.Demux.NextAu(S.Queue, Au);
  var Es := FMemory.Read32(AuPtr + 16);
  if (Es >= Cardinal(Low(Inst.EsBufs))) and (Es <= Cardinal(High(Inst.EsBufs))) then
  begin
    Inst.EsBufs[Es].Data := Au.Data;
    Inst.EsBufs[Es].Pts := Au.Pts;
    Inst.EsBufs[Es].Dts := Au.Dts;
  end;
  WriteAu(AuPtr, Au, Es, False);
  if AttrPtr <> 0 then
    FMemory.Write32(AttrPtr, (Au.Flags shr 7) and 1);
  FreePackets(Inst);
  Delay(100, 0);
end;

procedure TPSPMpeg.hGetAtracAu;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var AuPtr := FHLE.Arg(2);
  var OutPtr := FHLE.Arg(3);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var S := StreamAt(Inst, FHLE.Arg(1));
  if (S = nil) or (S.Queue = nil) or (S.Kind <> PSMFKindAtrac) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  if not FillQueue(Inst, S.Queue) then
  begin
    FHLE.Result(ERROR_MPEG_NO_DATA);
    Exit;
  end;
  var Au: TPSPAccessUnit;
  Inst.Demux.NextAu(S.Queue, Au);
  var Es := FMemory.Read32(AuPtr + 16);
  if (Es <> 0) and (Length(Au.Data) > 0) and FMemory.Valid(Es, Length(Au.Data)) then
    FMemory.WriteBytes(Es, Au.Data[0], Length(Au.Data));
  WriteAu(AuPtr, Au, Es, True);
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, Es);
  FreePackets(Inst);
  Delay(100, 0);
end;

procedure TPSPMpeg.hGetPcmAu;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  FHLE.Unimplemented('PCM streams');
  FHLE.Result(ERROR_MPEG_NO_DATA);
end;

procedure TPSPMpeg.hChangeGetAuMode;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var S := StreamAt(Inst, FHLE.Arg(1));
  if S = nil then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  // Mode 1 skips the stream: its data is dropped as the packs go by.
  if S.Queue <> nil then
  begin
    S.Queue.Active := FHLE.ArgInt(2) = 0;
    if not S.Queue.Active then
      S.Queue.Discard;
  end;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hChangeGetAvcAuMode;
begin
  FHLE.Result(0);
end;

procedure TPSPMpeg.WritePictureTo(Inst: TPSPMpegInstance; const Pic: TPSPPicture; Buffer: Cardinal; Width: Integer);
begin
  if (Buffer = 0) or (Width <= 0) or (Pic.Width <= 0) then
    Exit;
  var Bpp := PSPPixelBytes(Inst.PixelFormat);
  var Bytes := Cardinal((Pic.Height - 1) * Width + Pic.Width) * Cardinal(Bpp);
  var Dest := FMemory.Ptr(Buffer, Bytes);
  if Dest = nil then
    Exit;
  PSPWritePicture(Pic, Dest, Width, Inst.PixelFormat);
  FMemory.Touched(Buffer, Bytes);
end;

function DecodeTimeUs(const Pic: TPSPPicture): Int64;
begin
  // The ME takes about 5 us per macroblock.
  Result := 100 + Int64((Pic.Width + 15) div 16) * ((Pic.Height + 15) div 16) * 5;
end;

function TPSPMpeg.DecodeAu(Inst: TPSPMpegInstance; AuPtr: Cardinal; out Pictures: TArray<TPSPPicture>): Cardinal;
begin
  // The access unit sceMpegGetAvcAu left in the ES buffer (or an ES buffer in
  // memory, which sceMp4 fills).
  Pictures := nil;
  Result := 0;
  var Es := FMemory.Read32(AuPtr + 16);
  var Data: TBytes := nil;
  if (Es >= Cardinal(Low(Inst.EsBufs))) and (Es <= Cardinal(High(Inst.EsBufs))) then
  begin
    Data := Inst.EsBufs[Es].Data;
    Inst.EsBufs[Es].Data := nil;
  end;
  var Size := FMemory.Read32(AuPtr + 20);
  if (Data = nil) and (Es > Cardinal(High(Inst.EsBufs))) and (Size > 0) and (Size < $100000) and
    FMemory.Valid(Es, Size) then
  begin
    SetLength(Data, Size);
    FMemory.ReadBytes(Es, Data[0], Size);
  end;
  if Cardinal(Length(Data)) > Size then
    SetLength(Data, Size);
  if Length(Data) > 0 then
  begin
    Result := Inst.Avc.Decode(Data, Pictures);
    if Result <> 0 then
      Exit;
  end;
  FMemory.Write32(AuPtr + 20, 0);
  if Length(Data) > 0 then
    UpdateCodecContext(Inst, Cardinal(Length(Data)), Pictures);
  if Length(Pictures) > 0 then
  begin
    Inst.LastPicture := Pictures[0];
    Inst.HasDetail := True;
    Inc(Inst.Pictures, Length(Pictures));
  end;
end;

procedure TPSPMpeg.hAvcDecode;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var AuPtr := FHLE.Arg(1);
  var Width := FHLE.ArgInt(2);
  var BufPtr := FHLE.Arg(3);
  var InitPtr := FHLE.Arg(4);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var Pictures: TArray<TPSPPicture>;
  var Err := DecodeAu(Inst, AuPtr, Pictures);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if (Length(Pictures) > 0) and (BufPtr <> 0) then
    WritePictureTo(Inst, Pictures[0], FMemory.Read32(BufPtr), Width);
  if InitPtr <> 0 then
    FMemory.Write32(InitPtr, Cardinal(Length(Pictures)));
  var Us: Int64 := 200;
  if Inst.Avc.HasPicture then
    Us := DecodeTimeUs(Inst.Avc.LastPicture);
  Delay(Us, 0);
end;

procedure TPSPMpeg.hAvcDecodeStop;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var Width := FHLE.ArgInt(1);
  var BufPtr := FHLE.Arg(2);
  var StatusPtr := FHLE.Arg(3);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var Pictures: TArray<TPSPPicture>;
  Inst.Avc.Drain(Pictures);
  for var I := 0 to High(Pictures) do
    if BufPtr <> 0 then
      WritePictureTo(Inst, Pictures[I], FMemory.Read32(BufPtr + Cardinal(I) * 4), Width);
  if Length(Pictures) > 0 then
  begin
    Inst.LastPicture := Pictures[0];
    Inc(Inst.Pictures, Length(Pictures));
  end;
  if StatusPtr <> 0 then
    FMemory.Write32(StatusPtr, Cardinal(Length(Pictures)));
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcDecodeFlush;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  Inst.Avc.Reset;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcDecodeMode;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var ModePtr := FHLE.Arg(1);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  if ModePtr = 0 then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var Format := Integer(FMemory.Read32(ModePtr + 4));
  if (Format >= PSPPixel5650) and (Format <= PSPPixel8888) then
    Inst.PixelFormat := Format;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcDecodeDetail;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var Detail := FHLE.Arg(1);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  FMemory.Write32(Detail, 0);
  if not Inst.HasDetail then
  begin
    FHLE.Result(ERROR_MPEG_AVC_INVALID_VALUE);
    Exit;
  end;
  var P := Inst.LastPicture;
  var Ctx := Inst.Data + MpegCtxOffset + $30;
  // Whether the picture handed out and the unit just decoded are IDR, the
  // picture's size and crop, the stream parameters and the picture's records.
  FMemory.Write32(Detail + $04, Ord(P.Idr));
  FMemory.Write32(Detail + $08, Cardinal(P.Width));
  FMemory.Write32(Detail + $0C, Cardinal(P.Height));
  FMemory.Write32(Detail + $10, 0);
  FMemory.Write32(Detail + $14, 0);
  FMemory.Write32(Detail + $18, 0);
  FMemory.Write32(Detail + $1C, 0);
  FMemory.Write32(Detail + $20, 1);
  FMemory.Write32(Detail + $24, Ord(Inst.Avc.LastIdr));
  FMemory.Write32(Detail + $28, Ctx + $180);
  FMemory.Write32(Detail + $2C, FMemory.Read32(Ctx + $C0 + $24));
  FMemory.Write32(Detail + $30, FMemory.Read32(Ctx + $C0 + $28));
  FHLE.Result(0);
end;

// The ME's YCbCr buffer: a descriptor (macroblock rows and columns, two
// words, eight plane addresses, the picture's size) followed by the planes in
// the layout sceMpegBaseCscAvc reads: luma per field and macroblock column
// parity, chroma per field and plane.

function YCbCrPlanes(MbW, MbH: Integer; out Sizes: TArray<Cardinal>): Cardinal;
begin
  Result := $40 + PSPMePlaneSizes(MbW, MbH, Sizes);
end;

function TPSPMpeg.MePlanes(Addr: Cardinal; MbW, MbH: Integer; out Planes: TPSPMePlanes): Boolean;
begin
  // Addr holds the eight plane addresses.
  var Sizes: TArray<Cardinal>;
  PSPMePlaneSizes(MbW, MbH, Sizes);
  for var I := 0 to 7 do
  begin
    Planes[I] := FMemory.Ptr(FMemory.Read32(Addr + Cardinal(I) * 4), Sizes[I]);
    if Planes[I] = nil then
      Exit(False);
  end;
  Result := True;
end;

procedure TPSPMpeg.TouchPlanes(Addr: Cardinal; MbW, MbH: Integer);
begin
  var Sizes: TArray<Cardinal>;
  PSPMePlaneSizes(MbW, MbH, Sizes);
  for var I := 0 to 7 do
    FMemory.Touched(FMemory.Read32(Addr + Cardinal(I) * 4), Sizes[I]);
end;

procedure TPSPMpeg.hAvcQueryYCbCrSize;
begin
  var W := FHLE.ArgInt(2);
  var H := FHLE.ArgInt(3);
  var Out_ := FHLE.Arg(4);
  if (W <= 0) or (H <= 0) or (W > 1024) or (H > 1024) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var Sizes: TArray<Cardinal>;
  var Size := YCbCrPlanes((W + 15) div 16, (H + 15) div 16, Sizes);
  if Out_ <> 0 then
    FMemory.Write32(Out_, Size);
  FHLE.Result(0);
end;

procedure TPSPMpeg.InitYCbCr(Buf: Cardinal; W, H: Integer);
begin
  var MbW := (W + 15) div 16;
  var MbH := (H + 15) div 16;
  var Sizes: TArray<Cardinal>;
  YCbCrPlanes(MbW, MbH, Sizes);
  FMemory.Write32(Buf, Cardinal(MbH));
  FMemory.Write32(Buf + 4, Cardinal(MbW));
  FMemory.Write32(Buf + 8, 0);
  FMemory.Write32(Buf + 12, 1);
  var A := Buf + $40;
  for var I := 0 to 7 do
  begin
    FMemory.Write32(Buf + 16 + Cardinal(I) * 4, A);
    Inc(A, Sizes[I]);
  end;
  FMemory.Write32(Buf + 48, Cardinal(H));
  FMemory.Write32(Buf + 52, Cardinal(W));
end;

procedure TPSPMpeg.hAvcInitYCbCr;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var W := FHLE.ArgInt(2);
  var H := FHLE.ArgInt(3);
  var Buf := FHLE.Arg(4);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  if (Buf = 0) or (W <= 0) or (H <= 0) or (W > 1024) or (H > 1024) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  InitYCbCr(Buf, W, H);
  FHLE.Result(0);
end;

procedure TPSPMpeg.WriteYCbCr(const Pic: TPSPPicture; Buf: Cardinal);
begin
  if (Buf = 0) or not FMemory.Valid(Buf, $40) then
    Exit;
  var MbH := Integer(FMemory.Read32(Buf));
  var MbW := Integer(FMemory.Read32(Buf + 4));
  if (MbW * 16 < Pic.Width) or (MbH * 16 < Pic.Height) or (MbW > 64) or (MbH > 64) then
  begin
    InitYCbCr(Buf, Pic.Width, Pic.Height);
    MbH := (Pic.Height + 15) div 16;
    MbW := (Pic.Width + 15) div 16;
  end;
  var Planes: TPSPMePlanes;
  if MePlanes(Buf + 16, MbW, MbH, Planes) then
  begin
    PSPWriteMePlanes(Pic, Planes, MbW, MbH);
    TouchPlanes(Buf + 16, MbW, MbH);
    Exit;
  end;
  var Bufs: array[0..7] of Cardinal;
  for var I := 0 to 7 do
    Bufs[I] := FMemory.Read32(Buf + 16 + Cardinal(I) * 4);
  var FieldRows := MbH * 8;
  var CW := (Pic.Width + 1) div 2;
  for var Y := 0 to Pic.Height - 1 do
  begin
    var Field := Y and 1;
    var Row := Y div 2;
    for var X := 0 to Pic.Width - 1 do
    begin
      var Mb := X div 16;
      FMemory.Write8(Bufs[Field * 2 + (Mb and 1)] + Cardinal(((Mb div 2) * FieldRows + Row) * 16 + (X and 15)),
        Pic.Y[Y * Pic.Width + X]);
    end;
  end;
  // Each field keeps the chroma rows of its parity.
  var CH := (Pic.Height + 1) div 2;
  for var F := 0 to 1 do
    for var K := 0 to MbH * 4 - 1 do
    begin
      var SrcRow := 2 * K + F;
      if SrcRow >= CH then
        Break;
      for var X := 0 to CW - 1 do
      begin
        var C := Cardinal(K * (MbW * 8) + X);
        var S := SrcRow * CW + X;
        FMemory.Write8(Bufs[4 + F * 2] + C, Pic.Cb[S]);
        FMemory.Write8(Bufs[5 + F * 2] + C, Pic.Cr[S]);
      end;
    end;
end;

procedure TPSPMpeg.hAvcDecodeYCbCr;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var AuPtr := FHLE.Arg(1);
  var BufPtr := FHLE.Arg(2);
  var InitPtr := FHLE.Arg(3);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var Pictures: TArray<TPSPPicture>;
  var Err := DecodeAu(Inst, AuPtr, Pictures);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if (Length(Pictures) > 0) and (BufPtr <> 0) then
    WriteYCbCr(Pictures[0], FMemory.Read32(BufPtr));
  if InitPtr <> 0 then
    FMemory.Write32(InitPtr, Cardinal(Length(Pictures)));
  var Us: Int64 := 200;
  if Inst.Avc.HasPicture then
    Us := DecodeTimeUs(Inst.Avc.LastPicture);
  Delay(Us, 0);
end;

procedure TPSPMpeg.hAvcDecodeStopYCbCr;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var BufPtr := FHLE.Arg(1);
  var StatusPtr := FHLE.Arg(2);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  var Pictures: TArray<TPSPPicture>;
  Inst.Avc.Drain(Pictures);
  for var I := 0 to High(Pictures) do
    if BufPtr <> 0 then
      WriteYCbCr(Pictures[I], FMemory.Read32(BufPtr + Cardinal(I) * 4));
  if Length(Pictures) > 0 then
    Inst.LastPicture := Pictures[0];
  if StatusPtr <> 0 then
    FMemory.Write32(StatusPtr, Cardinal(Length(Pictures)));
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcCsc;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var Src := FHLE.Arg(1);
  var Range := FHLE.Arg(2);
  var Stride := FHLE.ArgInt(3);
  var Dest := FHLE.Arg(4);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  if (Src = 0) or (Range = 0) or (Dest = 0) or (Stride <= 0) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var X0 := Integer(FMemory.Read32(Range));
  var Y0 := Integer(FMemory.Read32(Range + 4));
  var W := Integer(FMemory.Read32(Range + 8));
  var H := Integer(FMemory.Read32(Range + 12));
  var MbH := Integer(FMemory.Read32(Src));
  var MbW := Integer(FMemory.Read32(Src + 4));
  if (X0 < 0) or (Y0 < 0) or (W <= 0) or (H <= 0) or (X0 + W > MbW * 16) or (Y0 + H > MbH * 16) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  CscAvc(Dest, 0, Stride, Src, X0, Y0, W, H, Inst.PixelFormat, True);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAtracDecode;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  var AuPtr := FHLE.Arg(1);
  var Buffer := FHLE.Arg(2);
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  if AuPtr = 0 then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var Es := FMemory.Read32(AuPtr + 16);
  var Size := FMemory.Read32(AuPtr + 20);
  if (Size < 8) or (Es = 0) or not FMemory.Valid(Es, Size) then
  begin
    Delay(200, ERROR_MPEG_ATRAC_NO_DATA);
    Exit;
  end;
  var Frame: TBytes;
  SetLength(Frame, Size);
  FMemory.ReadBytes(Es, Frame[0], Size);
  var Pcm: TArray<SmallInt> := nil;
  if (Frame[0] = $0F) and (Frame[1] = $D0) then
  begin
    var Channels := (Frame[2] shr 2) and 7;
    if Channels <> 1 then
      Channels := 2;
    try
      if Inst.Atrac = nil then
        Inst.Atrac := TATRAC3PlusDecoder.Create(Channels, 2);
      Pcm := Inst.Atrac.Decode(Copy(Frame, 8, Length(Frame) - 8));
    except
      on E: Exception do
        Pcm := nil;
    end;
  end;
  if Buffer <> 0 then
  begin
    if Length(Pcm) >= 4096 then
      FMemory.WriteBytes(Buffer, Pcm[0], 4096 * 2)
    else
      FMemory.Fill(Buffer, 0, 4096 * 2);
  end;
  FMemory.Write32(AuPtr + 20, 0);
  Delay(200, 0);
end;

procedure TPSPMpeg.hAvcResourceInit;
begin
  // The decoder's working memory and its ES buffer, which sceMp4 fills.
  if FEsBuf = 0 then
    FEsBuf := FKernel.AllocKernel($40000, 'avc es');
  if FDecTop = 0 then
    FDecTop := FKernel.AllocKernel($1000, 'avc dec top');
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcResourceFinish;
begin
  if FEsBuf <> 0 then
    FKernel.KernelPartition.FreeBlock(FEsBuf);
  if FDecTop <> 0 then
    FKernel.KernelPartition.FreeBlock(FDecTop);
  FEsBuf := 0;
  FDecTop := 0;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcResourceGetAvcDecTopAddr;
begin
  FHLE.Result(FDecTop);
end;

procedure TPSPMpeg.hAvcResourceGetAvcEsBuf;
begin
  FHLE.Result(FEsBuf);
end;

procedure TPSPMpeg.hZero;
begin
  FHLE.Result(0);
end;

procedure TPSPMpeg.hBaseCscInit;
begin
  FCscWidth := FHLE.ArgInt(0);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hBaseYCrCbCopyVme;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var Flags := FHLE.Arg(2);
  var H := Integer(FMemory.Read32(Src));
  var W := Integer(FMemory.Read32(Src + 4));
  if (W <= 0) or (H <= 0) or (W > 1024) or (H > 1024) or (W * H > 720 * 576) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  // Each half is copied in 128-byte lines of the ME's padded layout.
  var Lines := W div 16 + 2;
  if (W and $7F) = $50 then
    Inc(Lines);
  var LumaBytes := Cardinal(Lines * (H div 16) * 128);
  var ChromaBytes := LumaBytes div 4;
  for var Half := 0 to 1 do
    if (Flags and (1 shl Half)) <> 0 then
    begin
      var Bufs: array[0..2] of Integer;
      if Half = 0 then
      begin
        Bufs[0] := 0;
        Bufs[1] := 2;
        Bufs[2] := 3;
      end
      else
      begin
        Bufs[0] := 1;
        Bufs[1] := 4;
        Bufs[2] := 5;
      end;
      for var K := 0 to 2 do
      begin
        var S := FMemory.Read32(Src + 16 + Cardinal(Bufs[K]) * 4);
        var D := FMemory.Read32(Dst + 16 + Cardinal(Bufs[K]) * 4);
        var N := LumaBytes;
        if K > 0 then
          N := ChromaBytes;
        if (S <> 0) and (D <> 0) then
          FMemory.Copy(D, S, N);
      end;
    end;
  FHLE.Result(0);
end;

type
  TPSPCscSample = reference to procedure(Field, X, Row: Integer; out Y, Cb, Cr: Integer);

procedure CscFields(Memory: TPSPMemory; Out_, Second: Cardinal; Stride, W, H: Integer; SkipSecondField: Boolean;
  const Sample: TPSPCscSample);
begin
  // The ME keeps a picture as two fields: interleaved into one buffer when no
  // second buffer is given, otherwise the first field goes to the first buffer
  // and the second to the second one.
  var Rows := H div 2;
  for var F := 1 downto 0 do
  begin
    if (F = 1) and SkipSecondField then
      Continue;
    for var R := 0 to Rows - 1 do
    begin
      var Line: Cardinal;
      if Second = 0 then
        Line := Out_ + Cardinal((2 * R + F) * Stride) * 4
      else if F = 0 then
        Line := Out_ + Cardinal(R * Stride) * 4
      else
        Line := Second + Cardinal(R * Stride) * 4;
      for var X := 0 to W - 1 do
      begin
        var Y, Cb, Cr, Rv, Gv, Bv: Integer;
        Sample(F, X, R, Y, Cb, Cr);
        PSPYCbCrToRGB(Y, Cb, Cr, Rv, Gv, Bv);
        Memory.Write32(Line + Cardinal(X) * 4, PSPPackPixel(Rv, Gv, Bv, PSPPixel8888));
      end;
    end;
  end;
end;

procedure TPSPMpeg.hBaseCscVme;
begin
  var Out_ := FHLE.Arg(0);
  var Second := FHLE.Arg(1);
  var Stride := FHLE.ArgInt(2);
  var Desc := FHLE.Arg(3);
  var H := Integer(FMemory.Read32(Desc)) * 16;
  var W := Integer(FMemory.Read32(Desc + 4)) * 16;
  var Bufs: array[0..5] of Cardinal;
  for var I := 0 to 5 do
    Bufs[I] := FMemory.Read32(Desc + 16 + Cardinal(I) * 4);
  var Mem := FMemory;
  CscFields(FMemory, Out_, Second, Stride, W, H, False,
    procedure(Field, X, Row: Integer; out Y, Cb, Cr: Integer)
    begin
      Y := Mem.Read8(Bufs[Field] + Cardinal(Row * W + X));
      var C := Cardinal((Row div 2) * (W div 2) + X div 2);
      Cb := Mem.Read8(Bufs[2 + Field * 2] + C);
      Cr := Mem.Read8(Bufs[3 + Field * 2] + C);
    end);
  FHLE.Result(0);
end;

procedure TPSPMpeg.CscAvc(Out_, Second: Cardinal; Stride: Integer; Desc: Cardinal; X0, Y0, W, H, Format: Integer;
  Ranged: Boolean);
begin
  // The two fields of the ME's picture into a frame (interleaved rows), or
  // into a buffer each when a second one is given; Ranged converts the
  // rectangle X0, Y0, W, H only.
  var MbH := Integer(FMemory.Read32(Desc));
  var MbW := Integer(FMemory.Read32(Desc + 4));
  var OneField := not Ranged and (FMemory.Read32(Desc + 8) <> 0);
  if (MbW <= 0) or (MbH <= 0) or (MbW > 64) or (MbH > 64) then
    Exit;
  if not Ranged then
  begin
    X0 := 0;
    Y0 := 0;
    W := MbW * 16;
    H := MbH * 16;
  end;
  var Bpp := PSPPixelBytes(Format);
  var Planes: TPSPMePlanes;
  var Fast := MePlanes(Desc + 16, MbW, MbH, Planes);
  var FieldRows := MbH * 8;
  for var F := 1 downto 0 do
  begin
    if (F = 1) and OneField then
      Continue;
    var Y := Y0 + ((F - Y0) and 1);
    while Y < Y0 + H do
    begin
      var R := Y shr 1;
      var Line: Cardinal;
      if Second = 0 then
        Line := Out_ + Cardinal((Y - Y0) * Stride * Bpp)
      else if F = 0 then
        Line := Out_ + Cardinal(((Y - Y0) shr 1) * Stride * Bpp)
      else
        Line := Second + Cardinal(((Y - Y0) shr 1) * Stride * Bpp);
      var Dest := FMemory.Ptr(Line, Cardinal(W * Bpp));
      if Fast and (Dest <> nil) then
        PSPCscMeRow(Planes, MbW, MbH, F, R, X0, W, Dest, Format)
      else
        for var I := 0 to W - 1 do
        begin
          var X := X0 + I;
          var Mb := X div 16;
          var Yv := FMemory.Read8(FMemory.Read32(Desc + 16 + Cardinal(F * 2 + (Mb and 1)) * 4) + Cardinal(((Mb div 2) *
            FieldRows + R) * 16 + (X and 15)));
          var C := Cardinal((R div 2) * (MbW * 8) + X div 2);
          var Rv, Gv, Bv: Integer;
          PSPYCbCrToRGB(Yv, FMemory.Read8(FMemory.Read32(Desc + 16 + Cardinal(4 + F * 2) * 4) + C),
            FMemory.Read8(FMemory.Read32(Desc + 16 + Cardinal(5 + F * 2) * 4) + C), Rv, Gv, Bv);
          var P := PSPPackPixel(Rv, Gv, Bv, Format);
          if Bpp = 4 then
            FMemory.Write32(Line + Cardinal(I) * 4, P)
          else
            FMemory.Write16(Line + Cardinal(I) * 2, P);
        end;
      FMemory.Touched(Line, Cardinal(W * Bpp));
      Inc(Y, 2);
    end;
  end;
end;

function BaseCscFormat(Mode: Integer): Integer;
begin
  // sceMpegbase numbers the formats 8888, 5650, 5551, 4444.
  case Mode of
    1:
      Result := PSPPixel5650;
    2:
      Result := PSPPixel5551;
    3:
      Result := PSPPixel4444;
  else
    Result := PSPPixel8888;
  end;
end;

procedure TPSPMpeg.hBaseCscAvc;
begin
  CscAvc(FHLE.Arg(0), FHLE.Arg(1), FHLE.ArgInt(2), FHLE.Arg(3), 0, 0, 0, 0, BaseCscFormat(FCscMode), False);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hBaseCscAvcRange;
begin
  // (out, second, range in macroblocks {x, y, w, h}, stride, picture)
  var Range := FHLE.Arg(2);
  var Desc := FHLE.Arg(4);
  var MbH := Integer(FMemory.Read32(Desc));
  var MbW := Integer(FMemory.Read32(Desc + 4));
  var X0 := Integer(FMemory.Read32(Range));
  var Y0 := Integer(FMemory.Read32(Range + 4));
  var W := Integer(FMemory.Read32(Range + 8));
  var H := Integer(FMemory.Read32(Range + 12));
  if (X0 < 0) or (Y0 < 0) or (W <= 0) or (H <= 0) or (X0 + W > MbW) or (Y0 + H > MbH) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  CscAvc(FHLE.Arg(0), FHLE.Arg(1), FHLE.ArgInt(3), Desc, X0 * 16, Y0 * 16, W * 16, H * 16, BaseCscFormat(FCscMode),
    True);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hBaseCscMode;
begin
  FCscMode := FHLE.ArgInt(0) and 3;
  FHLE.Result(0);
end;

function ReadYCbCrDesc(Memory: TPSPMemory; Buf: Cardinal; out MbW, MbH: Integer; out Bufs: TArray<Cardinal>;
  out Sizes: TArray<Cardinal>): Boolean;
begin
  MbH := Integer(Memory.Read32(Buf));
  MbW := Integer(Memory.Read32(Buf + 4));
  Result := (MbW > 0) and (MbH > 0) and (MbW <= 64) and (MbH <= 64);
  SetLength(Bufs, 8);
  for var I := 0 to 7 do
    Bufs[I] := Memory.Read32(Buf + 16 + Cardinal(I) * 4);
  if Result then
    YCbCrPlanes(MbW, MbH, Sizes);
end;

procedure TPSPMpeg.hAvcConvertToYuv420;
begin
  // Planar YUV 4:2:0 out of the ME's two-field buffer.
  var Dst := FHLE.Arg(1);
  var Src := FHLE.Arg(2);
  var MbW, MbH: Integer;
  var Bufs, Sizes: TArray<Cardinal>;
  if (Dst = 0) or (Src = 0) or not ReadYCbCrDesc(FMemory, Src, MbW, MbH, Bufs, Sizes) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var W := MbW * 16;
  var H := MbH * 16;
  var FieldRows := MbH * 8;
  for var Y := 0 to H - 1 do
    for var X := 0 to W - 1 do
    begin
      var Mb := X div 16;
      FMemory.Write8(Dst + Cardinal(Y * W + X), FMemory.Read8(Bufs[(Y and 1) * 2 + (Mb and 1)] +
        Cardinal(((Mb div 2) * FieldRows + Y div 2) * 16 + (X and 15))));
    end;
  var CW := W div 2;
  var CH := H div 2;
  var U := Dst + Cardinal(W * H);
  var V := U + Cardinal(CW * CH);
  for var Row := 0 to CH - 1 do
    for var X := 0 to CW - 1 do
    begin
      var C := Cardinal((Row div 2) * CW + X);
      FMemory.Write8(U + Cardinal(Row * CW + X), FMemory.Read8(Bufs[4 + (Row and 1) * 2] + C));
      FMemory.Write8(V + Cardinal(Row * CW + X), FMemory.Read8(Bufs[5 + (Row and 1) * 2] + C));
    end;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcCopyYCbCr;
begin
  var Dst := FHLE.Arg(1);
  var Src := FHLE.Arg(2);
  var MbW, MbH: Integer;
  var Bufs, Sizes: TArray<Cardinal>;
  if (Dst = 0) or (Src = 0) or not ReadYCbCrDesc(FMemory, Src, MbW, MbH, Bufs, Sizes) then
  begin
    FHLE.Result(ERROR_MPEG_INVALID_VALUE);
    Exit;
  end;
  var DMbW, DMbH: Integer;
  var DBufs, DSizes: TArray<Cardinal>;
  if not ReadYCbCrDesc(FMemory, Dst, DMbW, DMbH, DBufs, DSizes) or (DMbW <> MbW) or (DMbH <> MbH) then
  begin
    InitYCbCr(Dst, MbW * 16, MbH * 16);
    ReadYCbCrDesc(FMemory, Dst, DMbW, DMbH, DBufs, DSizes);
  end;
  for var I := 0 to 7 do
    if (Bufs[I] <> 0) and (DBufs[I] <> 0) then
      FMemory.Copy(DBufs[I], Bufs[I], Sizes[I]);
  FHLE.Result(0);
end;

procedure TPSPMpeg.hBaseYCrCbCopy;
begin
  // Copies the fields Flags selects (bit 0 the first, bit 1 the second).
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var Flags := FHLE.Arg(2);
  var MbW, MbH: Integer;
  var Bufs, Sizes: TArray<Cardinal>;
  MbH := Integer(FMemory.Read32(Src));
  MbW := Integer(FMemory.Read32(Src + 4));
  // Unlike the destination and CSC descriptors, the copy source's dimensions
  // are pixels (the guest libmpeg constructs it from the codec's picture info).
  if (Dst = 0) or (Src = 0) or (MbW <= 0) or (MbH <= 0) or (MbW > 1024) or (MbH > 1024) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE);
    Exit;
  end;
  MbW := (MbW + 15) div 16;
  MbH := (MbH + 15) div 16;
  SetLength(Bufs, 8);
  for var I := 0 to 7 do
    Bufs[I] := FMemory.Read32(Src + 16 + Cardinal(I) * 4);
  PSPMePlaneSizes(MbW, MbH, Sizes);
  for var I := 0 to 7 do
  begin
    var Field := (I shr 1) and 1;
    if (Flags and (1 shl Field)) = 0 then
      Continue;
    var D := FMemory.Read32(Dst + 16 + Cardinal(I) * 4);
    if (Bufs[I] <> 0) and (D <> 0) then
      FMemory.Copy(D, Bufs[I], Sizes[I]);
  end;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hBasePESpacketCopy;
begin
  // A DMA list: {source, destination, next, size} entries, size in the low 12 bits.
  // Destinations below 2 MB are in the ME's memory.
  var Me := TPSPVideocodec(FSystem.Find(TPSPVideocodec));
  var Lli := FHLE.Arg(0);
  var Count := 0;
  while (Lli <> 0) and (Count < 4096) do
  begin
    var Src := FMemory.Read32(Lli);
    var Dst := FMemory.Read32(Lli + 4);
    var Next := FMemory.Read32(Lli + 8);
    var Size := FMemory.Read32(Lli + 12) and $FFF;
    if (Src <> 0) and (Dst <> 0) and (Size > 0) then
    begin
      var S := FMemory.Ptr(Src, Size);
      var D := FMemory.Ptr(Dst, Size);
      if D <> nil then
        FMemory.Touched(Dst, Size)
      else if Me <> nil then
        D := Me.MePtr(Dst, Size);
      if (S <> nil) and (D <> nil) then
        Move(S^, D^, Size);
    end;
    Lli := Next;
    Inc(Count);
  end;
  FHLE.Result(0);
end;

procedure TPSPMpeg.hAvcDecodeDetail2;
begin
  var Inst := InstanceOf(FHLE.Arg(0));
  if Inst = nil then
  begin
    FHLE.Result(ERROR_MPEG_NOT_YET_INIT);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), FMemory.Read32(Inst.Handle + $6C0));
  FHLE.Result(0);
end;

procedure TPSPMpeg.hVideocodecGetSEI;
begin
  // The ME copies the last decoded unit's SEI record to the buffer at ctx+50.
  var Ctx := FHLE.Arg(0);
  for var Inst in FInstances do
    if Inst.Data + MpegCtxOffset + $30 = Ctx then
    begin
      var Dest := FMemory.Read32(Ctx + $50);
      var R := Inst.Avc.CurrentRecord;
      if (Dest <> 0) and (Length(R) > 0) and FMemory.Valid(Dest, Length(R) * 4) then
        FMemory.WriteBytes(Dest, R[0], Length(R) * 4);
      FHLE.Result(0);
      Exit;
    end;
  FHLE.Result(ERROR_MPEG_INVALID_VALUE);
end;

initialization
  RegisterPSPService(TPSPMpeg);

end.
