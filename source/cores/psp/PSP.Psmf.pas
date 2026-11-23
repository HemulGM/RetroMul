unit PSP.Psmf;

// scePsmf / scePsmfPlayer: PSMF headers and the movie player.
// The player reads the whole movie when it is set, decodes pictures as they
// are asked for and presents them on the clock scePsmfPlayerUpdate advances:
// half a 29.97 Hz frame per call (one vblank), at most one new picture per
// scePsmfPlayerGetVideoData.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service, PSP.MpegDemux, PSP.MpegVideo,
  Audio.ATRAC3Plus;

const
  ERROR_PSMFPLAYER_INVALID_STATUS = Cardinal($80616001);
  ERROR_PSMFPLAYER_INVALID_STREAM = Cardinal($80616003);
  ERROR_PSMFPLAYER_BUFFER_SIZE = Cardinal($80616005);
  ERROR_PSMFPLAYER_INVALID_CONFIG = Cardinal($80616006);
  ERROR_PSMFPLAYER_INVALID_PARAM = Cardinal($80616008);
  ERROR_PSMFPLAYER_NO_MORE_DATA = Cardinal($8061600C);
  ERROR_PSMF_NOT_INITIALIZED = Cardinal($80615001);
  ERROR_PSMF_BAD_VERSION = Cardinal($80615002);
  ERROR_PSMF_NOT_FOUND = Cardinal($80615025);
  ERROR_PSMF_INVALID_ID = Cardinal($80615100);
  ERROR_PSMF_INVALID_VALUE = Cardinal($806151FE);
  ERROR_PSMF_INVALID_TIMESTAMP = Cardinal($80615500);
  ERROR_PSMF_INVALID_PSMF = Cardinal($80615501);

const
  PsmfStatusNone = 0;
  PsmfStatusInit = 1;
  PsmfStatusStandby = 2;
  PsmfStatusPlaying = 4;
  PsmfStatusFinished = $200;

type
  TPSPPsmfPlayer = class
  public
    Handle: Cardinal;
    Status: Integer;
    Buffer, BufferSize: Cardinal;
    Priority: Integer;
    Header: TPSPPsmfHeader;
    Data: TBytes;
    StreamStart: Integer;
    Loop: Boolean;
    PixelMode: Integer;
    VideoCodec, VideoNum, AudioCodec, AudioNum: Integer;
    Mode, Speed: Integer;
    HasAudio: Boolean;
    // Playback
    Demux: TPSPPsDemux;
    VideoQ, AudioQ: TPSPEsQueue;
    Avc: TPSPAvc;
    Atrac: TATRAC3PlusDecoder;
    PackPos: Integer;
    // Where Start's initial pts put playback: a pack (from the EP map) and its picture.
    SeekPack, FirstFrame: Integer;
    Ready: TQueue<TPSPPicture>;
    Decoded, AudioFrames: Integer;
    StreamDone: Boolean;
    Shown: Integer;
    ShownPic: TPSPPicture;
    Updates, NextDue: Integer;
    AfterLast: Integer;
    // The selected stream has no data in the file: nothing will ever show.
    Starved: Boolean;
    // Work of the player's thread that runs once the caller gives up the CPU.
    PendingFinish: Boolean;
    DeferNow, DeferClocks: Int64;
    LastVideoUpdates: Integer;
    ForceWrite: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure StopPlayback;
    procedure StartPlayback;
    function NextPicture(out Pic: TPSPPicture): Boolean;
    function NextAudio(out Pcm: TArray<SmallInt>): Boolean;
  end;

  // A scePsmf handle: the guest's struct address and what was parsed into it.
  TPSPPsmfData = class
  public
    Address: Cardinal;
    Header: TPSPPsmfHeader;
    Current: Integer;
  end;

  TPSPPsmf = class(TPSPService)
  private
    FPlayers: TObjectList<TPSPPsmfPlayer>;
    FPsmfs: TObjectList<TPSPPsmfData>;
    function PlayerOf(Ptr: Cardinal): TPSPPsmfPlayer;
    function PsmfOf(Ptr: Cardinal): TPSPPsmfData;
    procedure Delay(Us: Int64; Value: Cardinal);
    procedure SetPsmfCommon(Offset: Int64);
    procedure WriteVideo(P: TPSPPsmfPlayer; Buffer: Cardinal; Width: Integer);
    procedure CheckEnd(P: TPSPPsmfPlayer);
    procedure Finish(P: TPSPPsmfPlayer);
    procedure ThreadWork(P: TPSPPsmfPlayer);
    procedure CatchUp(P: TPSPPsmfPlayer);
    procedure Yielding(P: TPSPPsmfPlayer);
    function AdvanceVideo(P: TPSPPsmfPlayer): Boolean;
    // scePsmfPlayer
    procedure hPlayerCreate;
    procedure hPlayerDelete;
    procedure hPlayerSetPsmf;
    procedure hPlayerSetPsmfOffset;
    procedure hPlayerReleasePsmf;
    procedure hPlayerSetTempBuf;
    procedure hPlayerGetAudioOutSize;
    procedure hPlayerGetPsmfInfo;
    procedure hPlayerStart;
    procedure hPlayerStop;
    procedure hPlayerBreak;
    procedure hPlayerUpdate;
    procedure hPlayerGetVideoData;
    procedure hPlayerGetAudioData;
    procedure hPlayerGetCurrentStatus;
    procedure hPlayerGetCurrentPts;
    procedure hPlayerConfigPlayer;
    procedure hPlayerGetCurrentVideoStream;
    procedure hPlayerGetCurrentAudioStream;
    procedure SelectStream(Kind: Integer; Specific: Boolean);
    procedure hPlayerSelectVideo;
    procedure hPlayerSelectAudio;
    procedure hPlayerSelectSpecificVideo;
    procedure hPlayerSelectSpecificAudio;
    procedure hPlayerGetCurrentPlayMode;
    procedure hPlayerChangePlayMode;
    // scePsmf
    procedure hSetPsmf;
    procedure hVerifyPsmf;
    procedure hQueryStreamOffset;
    procedure hQueryStreamSize;
    procedure hGetPsmfVersion;
    procedure hGetHeaderSize;
    procedure hGetStreamSize;
    procedure hGetPresentationStartTime;
    procedure hGetPresentationEndTime;
    procedure hGetNumberOfStreams;
    procedure hGetNumberOfSpecificStreams;
    procedure hSpecifyStream;
    procedure hSpecifyStreamWithStreamType;
    procedure hSpecifyStreamWithStreamTypeNumber;
    procedure hGetCurrentStreamType;
    procedure hGetCurrentStreamNumber;
    procedure hGetVideoInfo;
    procedure hGetAudioInfo;
    procedure hGetNumberOfEPentries;
    procedure hCheckEPMap;
    procedure hGetEPWithId;
    procedure hGetEPWithTimestamp;
    procedure hGetEPidWithTimestamp;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  System.Math, PSP.Mpeg;

const
  LibPlayer = 'scePsmfPlayer';
  LibPsmf = 'scePsmf';
  FrameTicks = 3003;

{ TPSPPsmfPlayer }

constructor TPSPPsmfPlayer.Create;
begin
  inherited Create;
  Ready := TQueue<TPSPPicture>.Create;
  PixelMode := -1;
  Mode := 0;
  Speed := 1;
  VideoCodec := -1;
  VideoNum := -1;
  AudioCodec := -1;
  AudioNum := -1;
  Shown := -1;
end;

destructor TPSPPsmfPlayer.Destroy;
begin
  StopPlayback;
  Ready.Free;
  inherited;
end;

procedure TPSPPsmfPlayer.StopPlayback;
begin
  FreeAndNil(Demux);
  FreeAndNil(Avc);
  FreeAndNil(Atrac);
  VideoQ := nil;
  AudioQ := nil;
  Ready.Clear;
  Decoded := 0;
  AudioFrames := 0;
  StreamDone := False;
  Shown := -1;
  Updates := 0;
  NextDue := 5;
  AfterLast := 0;
  Starved := False;
  PendingFinish := False;
  LastVideoUpdates := -1;
  ForceWrite := True;
end;

procedure TPSPPsmfPlayer.StartPlayback;
begin
  StopPlayback;
  Demux := TPSPPsDemux.Create;
  Avc := TPSPAvc.Create;
  var V := Header.Find(PSMFKindAvc, VideoNum);
  Starved := V < 0;
  if V >= 0 then
  begin
    VideoQ := Demux.AddStream(PSMFKindAvc, Header.Streams[V].StreamId, 0);
    if not PSMFStreamPresent(Data, StreamStart, Header.Streams[V].StreamId, 0) then
      Starved := True;
  end;
  if HasAudio then
  begin
    var A := Header.Find(PSMFKindAtrac, AudioNum);
    if A >= 0 then
    begin
      AudioQ := Demux.AddStream(PSMFKindAtrac, $BD, Header.Streams[A].PrivateId);
      if not PSMFStreamPresent(Data, StreamStart, $BD, Header.Streams[A].PrivateId) then
        Starved := True;
    end;
  end;
  PackPos := StreamStart + SeekPack * PSMFPacketSize;
end;

function TPSPPsmfPlayer.NextPicture(out Pic: TPSPPicture): Boolean;
begin
  // Decodes until a picture comes out of the decoder.
  Pic := Default(TPSPPicture);
  while Ready.Count = 0 do
  begin
    if StreamDone or (VideoQ = nil) then
      Exit(False);
    while not Demux.HasAu(VideoQ) and (PackPos + PSMFPacketSize <= Length(Data)) do
    begin
      Demux.FeedPack(@Data[PackPos]);
      Inc(PackPos, PSMFPacketSize);
    end;
    var Au: TPSPAccessUnit;
    var Pictures: TArray<TPSPPicture>;
    if Demux.NextAu(VideoQ, Au, PackPos + PSMFPacketSize > Length(Data)) then
    begin
      if Avc.Decode(Au.Data, Pictures) <> 0 then
        Pictures := nil;
    end
    else
    begin
      Avc.Drain(Pictures);
      StreamDone := True;
    end;
    for var X in Pictures do
      Ready.Enqueue(X);
    Demux.TakeFreed;
  end;
  Pic := Ready.Dequeue;
  Inc(Decoded);
  Result := True;
end;

function TPSPPsmfPlayer.NextAudio(out Pcm: TArray<SmallInt>): Boolean;
begin
  Pcm := nil;
  if AudioQ = nil then
    Exit(False);
  while not Demux.HasAu(AudioQ) and (PackPos + PSMFPacketSize <= Length(Data)) do
  begin
    Demux.FeedPack(@Data[PackPos]);
    Inc(PackPos, PSMFPacketSize);
  end;
  var Au: TPSPAccessUnit;
  if not Demux.NextAu(AudioQ, Au) then
    Exit(False);
  Demux.TakeFreed;
  Inc(AudioFrames);
  try
    if Atrac = nil then
      Atrac := TATRAC3PlusDecoder.Create(2, 2);
    if (Length(Au.Data) > 8) and (Au.Data[0] = $0F) and (Au.Data[1] = $D0) then
      Pcm := Atrac.Decode(Copy(Au.Data, 8, Length(Au.Data) - 8));
  except
    on E: Exception do
      Pcm := nil;
  end;
  if Length(Pcm) < 4096 then
    SetLength(Pcm, 4096);
  Result := True;
end;

{ TPSPPsmf }

constructor TPSPPsmf.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FPlayers := TObjectList<TPSPPsmfPlayer>.Create(True);
  FPsmfs := TObjectList<TPSPPsmfData>.Create(True);
end;

destructor TPSPPsmf.Destroy;
begin
  FPlayers.Free;
  FPsmfs.Free;
  inherited;
end;

procedure TPSPPsmf.Reset;
begin
  FPlayers.Clear;
  FPsmfs.Clear;
end;

procedure TPSPPsmf.Register;
begin
  var H := FHLE;
  H.Register(LibPlayer, $235D8787, 'scePsmfPlayerCreate', hPlayerCreate);
  H.Register(LibPlayer, $9B71A274, 'scePsmfPlayerDelete', hPlayerDelete);
  H.Register(LibPlayer, $3D6D25A9, 'scePsmfPlayerSetPsmf', hPlayerSetPsmf);
  H.Register(LibPlayer, $58B83577, 'scePsmfPlayerSetPsmfCB', hPlayerSetPsmf);
  H.Register(LibPlayer, $76C0F4AE, 'scePsmfPlayerSetPsmfOffset', hPlayerSetPsmfOffset);
  H.Register(LibPlayer, $A72DB4F9, 'scePsmfPlayerSetPsmfOffsetCB', hPlayerSetPsmfOffset);
  H.Register(LibPlayer, $E792CD94, 'scePsmfPlayerReleasePsmf', hPlayerReleasePsmf);
  H.Register(LibPlayer, $2D0E4E0A, 'scePsmfPlayerSetTempBuf', hPlayerSetTempBuf);
  H.Register(LibPlayer, $3EA82A4B, 'scePsmfPlayerGetAudioOutSize', hPlayerGetAudioOutSize);
  H.Register(LibPlayer, $DF089680, 'scePsmfPlayerGetPsmfInfo', hPlayerGetPsmfInfo);
  H.Register(LibPlayer, $95A84EE5, 'scePsmfPlayerStart', hPlayerStart);
  H.Register(LibPlayer, $1078C008, 'scePsmfPlayerStop', hPlayerStop);
  H.Register(LibPlayer, $2BEB1569, 'scePsmfPlayerBreak', hPlayerBreak);
  H.Register(LibPlayer, $A0B8CA55, 'scePsmfPlayerUpdate', hPlayerUpdate);
  H.Register(LibPlayer, $46F61F8B, 'scePsmfPlayerGetVideoData', hPlayerGetVideoData);
  H.Register(LibPlayer, $B9848A74, 'scePsmfPlayerGetAudioData', hPlayerGetAudioData);
  H.Register(LibPlayer, $F8EF08A6, 'scePsmfPlayerGetCurrentStatus', hPlayerGetCurrentStatus);
  H.Register(LibPlayer, $3ED62233, 'scePsmfPlayerGetCurrentPts', hPlayerGetCurrentPts);
  H.Register(LibPlayer, $1E57A8E7, 'scePsmfPlayerConfigPlayer', hPlayerConfigPlayer);
  H.Register(LibPlayer, $9FF2B2E7, 'scePsmfPlayerGetCurrentVideoStream', hPlayerGetCurrentVideoStream);
  H.Register(LibPlayer, $68F07175, 'scePsmfPlayerGetCurrentAudioStream', hPlayerGetCurrentAudioStream);
  H.Register(LibPlayer, $8A9EBDCD, 'scePsmfPlayerSelectVideo', hPlayerSelectVideo);
  H.Register(LibPlayer, $B8D10C56, 'scePsmfPlayerSelectAudio', hPlayerSelectAudio);
  H.Register(LibPlayer, $75F03FA2, 'scePsmfPlayerSelectSpecificVideo', hPlayerSelectSpecificVideo);
  H.Register(LibPlayer, $85461EFF, 'scePsmfPlayerSelectSpecificAudio', hPlayerSelectSpecificAudio);
  H.Register(LibPlayer, $F3EFAA91, 'scePsmfPlayerGetCurrentPlayMode', hPlayerGetCurrentPlayMode);
  H.Register(LibPlayer, $A3D81169, 'scePsmfPlayerChangePlayMode', hPlayerChangePlayMode);

  H.Register(LibPsmf, $C22C8327, 'scePsmfSetPsmf', hSetPsmf);
  H.Register(LibPsmf, $2673646B, 'scePsmfVerifyPsmf', hVerifyPsmf);
  H.Register(LibPsmf, $5B70FCC1, 'scePsmfQueryStreamOffset', hQueryStreamOffset);
  H.Register(LibPsmf, $9553CC91, 'scePsmfQueryStreamSize', hQueryStreamSize);
  H.Register(LibPsmf, $E1283895, 'scePsmfGetPsmfVersion', hGetPsmfVersion);
  H.Register(LibPsmf, $B78EB9E9, 'scePsmfGetHeaderSize', hGetHeaderSize);
  H.Register(LibPsmf, $A5EBFE81, 'scePsmfGetStreamSize', hGetStreamSize);
  H.Register(LibPsmf, $76D3AEBA, 'scePsmfGetPresentationStartTime', hGetPresentationStartTime);
  H.Register(LibPsmf, $BD8AE0D8, 'scePsmfGetPresentationEndTime', hGetPresentationEndTime);
  H.Register(LibPsmf, $EAED89CD, 'scePsmfGetNumberOfStreams', hGetNumberOfStreams);
  H.Register(LibPsmf, $68D42328, 'scePsmfGetNumberOfSpecificStreams', hGetNumberOfSpecificStreams);
  H.Register(LibPsmf, $4BC9BDE0, 'scePsmfSpecifyStream', hSpecifyStream);
  H.Register(LibPsmf, $1E6D9013, 'scePsmfSpecifyStreamWithStreamType', hSpecifyStreamWithStreamType);
  H.Register(LibPsmf, $0C120E1D, 'scePsmfSpecifyStreamWithStreamTypeNumber', hSpecifyStreamWithStreamTypeNumber);
  H.Register(LibPsmf, $C7DB3A5B, 'scePsmfGetCurrentStreamType', hGetCurrentStreamType);
  H.Register(LibPsmf, $28240568, 'scePsmfGetCurrentStreamNumber', hGetCurrentStreamNumber);
  H.Register(LibPsmf, $0BA514E5, 'scePsmfGetVideoInfo', hGetVideoInfo);
  H.Register(LibPsmf, $A83F7113, 'scePsmfGetAudioInfo', hGetAudioInfo);
  H.Register(LibPsmf, $7491C438, 'scePsmfGetNumberOfEPentries', hGetNumberOfEPentries);
  H.Register(LibPsmf, $971A3A90, 'scePsmfCheckEPMap', hCheckEPMap);
  H.Register(LibPsmf, $4E624A34, 'scePsmfGetEPWithId', hGetEPWithId);
  H.Register(LibPsmf, $7C0E7AC3, 'scePsmfGetEPWithTimestamp', hGetEPWithTimestamp);
  H.Register(LibPsmf, $5F457515, 'scePsmfGetEPidWithTimestamp', hGetEPidWithTimestamp);
end;

function TPSPPsmf.PlayerOf(Ptr: Cardinal): TPSPPsmfPlayer;
begin
  if (Ptr = 0) or not FMemory.Valid(Ptr, 4) then
    Exit(nil);
  var H := FMemory.Read32(Ptr);
  if H = 0 then
    Exit(nil);
  for var P in FPlayers do
    if P.Handle = H then
    begin
      CatchUp(P);
      Exit(P);
    end;
  Result := nil;
end;

function TPSPPsmf.PsmfOf(Ptr: Cardinal): TPSPPsmfData;
begin
  for var P in FPsmfs do
    if P.Address = Ptr then
      Exit(P);
  Result := nil;
end;

procedure TPSPPsmf.Delay(Us: Int64; Value: Cardinal);
begin
  FHLE.Result(Value);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'psmf');
  if T.Wait.HLETag <> 'psmf' then
    Exit;
  T.Wait.Data[0] := Value;
  FKernel.AddWakeTimer(FKernel.Scheduler.Now + Us * 1000, T, 'psmf', Value, 0);
end;

{ scePsmfPlayer }

procedure TPSPPsmf.hPlayerCreate;
begin
  var Ptr := FHLE.Arg(0);
  var Cfg := FHLE.Arg(1);
  var Buf := FMemory.Read32(Cfg);
  var Size := FMemory.Read32(Cfg + 4);
  var Prio := Integer(FMemory.Read32(Cfg + 8));
  if Size < $285800 then
  begin
    FMemory.Write32(Ptr, 0);
    FHLE.Result(ERROR_PSMFPLAYER_BUFFER_SIZE);
    Exit;
  end;
  if (Prio < 16) or (Prio > 109) then
  begin
    FMemory.Write32(Ptr, 0);
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
    Exit;
  end;
  // The player's sceMpeg needs sceMpegInit (probe psmf_create).
  var Mpeg := TPSPMpeg(FSystem.Find(TPSPMpeg));
  if (Mpeg <> nil) and not Mpeg.Initialized then
  begin
    FMemory.Write32(Ptr, 0);
    Delay(1000, $80618009);
    Exit;
  end;
  if FPlayers.Count > 0 then
  begin
    // The player's sceMpeg is taken.
    Delay(1000, $80618005);
    Exit;
  end;
  var P := TPSPPsmfPlayer.Create;
  P.Buffer := Buf;
  P.BufferSize := Size;
  P.Priority := Prio;
  P.Status := PsmfStatusInit;
  P.Handle := FKernel.AllocKernel(16, 'psmfplayer');
  FMemory.Write32(P.Handle, P.Handle + 8);
  FMemory.Write32(P.Handle + 4, 0);
  FMemory.Write32(P.Handle + 8, 0);
  FPlayers.Add(P);
  FMemory.Write32(Ptr, P.Handle);
  Delay(1000, 0);
end;

procedure TPSPPsmf.hPlayerDelete;
begin
  var Ptr := FHLE.Arg(0);
  var P := PlayerOf(Ptr);
  if P = nil then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  FKernel.KernelPartition.FreeBlock(P.Handle);
  FPlayers.Remove(P);
  FMemory.Write32(Ptr, 0);
  Delay(1000, 0);
end;

procedure TPSPPsmf.SetPsmfCommon(Offset: Int64);
begin
  var P := PlayerOf(FHLE.Arg(0));
  var Name := FHLE.Arg(1);
  if (P = nil) or (P.Status <> PsmfStatusInit) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  if Name = 0 then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
    Exit;
  end;
  var Path := FMemory.ReadString(Name, 1024);
  var Data: TBytes;
  var Err := FSystem.IO.ReadAll(Path, Data);
  var Header: TPSPPsmfHeader;
  if (Err <> 0) or (Offset < 0) or (Offset + PSMFPacketSize > Length(Data)) or (Header.Parse(Copy(Data, Offset,
        PSMFPacketSize)) <> 0) then
  begin
    Delay(2000, SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  if Offset > 0 then
    Data := Copy(Data, Offset, Length(Data) - Offset);
  P.Data := Data;
  P.Header := Header;
  P.StreamStart := Header.HeaderSize;
  P.Status := PsmfStatusStandby;
  Delay(2000, 0);
end;

procedure TPSPPsmf.hPlayerSetPsmf;
begin
  SetPsmfCommon(0);
end;

procedure TPSPPsmf.hPlayerSetPsmfOffset;
begin
  SetPsmfCommon(FHLE.ArgInt(2));
end;

procedure TPSPPsmf.hPlayerReleasePsmf;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or not (P.Status in [PsmfStatusStandby, PsmfStatusPlaying]) and (P.Status <> PsmfStatusFinished) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  P.StopPlayback;
  P.Data := nil;
  P.Header := Default(TPSPPsmfHeader);
  P.Status := PsmfStatusInit;
  Delay(1000, 0);
end;

procedure TPSPPsmf.hPlayerSetTempBuf;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or (P.Status <> PsmfStatusInit) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  if FHLE.Arg(2) < $10000 then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
    Exit;
  end;
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerGetAudioOutSize;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if P = nil then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  FHLE.Result($2000);
end;

procedure TPSPPsmf.hPlayerGetPsmfInfo;
begin
  var P := PlayerOf(FHLE.Arg(0));
  var Info := FHLE.Arg(1);
  if (P = nil) or (P.Status < PsmfStatusStandby) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  FMemory.Write32(Info, Cardinal(P.Header.EndTime - P.Header.StartTime - FrameTicks));
  FMemory.Write32(Info + 4, Cardinal(P.Header.Count(PSMFKindAvc)));
  FMemory.Write32(Info + 8, Cardinal(P.Header.Count(PSMFKindAtrac)));
  FMemory.Write32(Info + 12, Cardinal(P.Header.Count(PSMFKindPcm)));
  FMemory.Write32(Info + 16, 1);
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerStart;
begin
  var P := PlayerOf(FHLE.Arg(0));
  var D := FHLE.Arg(1);
  var InitPts := FHLE.ArgInt(2);
  if (P = nil) or (P.Status < PsmfStatusStandby) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  var VCodec := Integer(FMemory.Read32(D));
  var VNum := Integer(FMemory.Read32(D + 4));
  var ACodec := Integer(FMemory.Read32(D + 8));
  var ANum := Integer(FMemory.Read32(D + 12));
  var PMode := Integer(FMemory.Read32(D + 16));
  var PSpeed := Integer(FMemory.Read32(D + 20));
  if (PMode < 0) or (PMode > 3) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
    Exit;
  end;
  // A start other than the beginning needs an entry point at or before it.
  var SeekPack := 0;
  var SeekFrame := 0;
  if InitPts <> 0 then
  begin
    var Entry := -1;
    var V := P.Header.Find(PSMFKindAvc, Max(VNum, 0));
    if (InitPts > 0) and (V >= 0) then
      for var E := 0 to High(P.Header.Streams[V].EP) do
        if P.Header.Streams[V].EP[E].Pts - P.Header.StartTime <= InitPts then
          Entry := E;
    if Entry < 0 then
    begin
      FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
      Exit;
    end;
    SeekPack := Integer(P.Header.Streams[V].EP[Entry].Offset);
    SeekFrame := Integer((P.Header.Streams[V].EP[Entry].Pts - P.Header.StartTime) div FrameTicks);
  end;
  if (VCodec <> 0) and (VCodec <> $0E) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STREAM);
    Exit;
  end;
  if (VNum < 0) or (P.Header.Find(PSMFKindAvc, VNum) < 0) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_CONFIG);
    Exit;
  end;
  var HasAudio := P.Header.Count(PSMFKindAtrac) > 0;
  if HasAudio then
  begin
    if (ACodec <> 1) and (ACodec <> $0F) then
    begin
      FHLE.Result(ERROR_PSMFPLAYER_INVALID_STREAM);
      Exit;
    end;
    if (ANum < 0) or (P.Header.Find(PSMFKindAtrac, ANum) < 0) then
    begin
      FHLE.Result(ERROR_PSMFPLAYER_INVALID_CONFIG);
      Exit;
    end;
  end;
  var OldVideo := P.VideoNum;
  var OldAudio := P.AudioNum;
  P.VideoCodec := 0;
  P.VideoNum := VNum;
  P.HasAudio := HasAudio;
  if HasAudio then
  begin
    P.AudioCodec := 1;
    P.AudioNum := ANum;
  end
  else
  begin
    P.AudioCodec := -1;
    P.AudioNum := -1;
  end;
  var Restart := (P.Status = PsmfStatusStandby) or (OldVideo <> P.VideoNum) or (OldAudio <> P.AudioNum);
  P.Mode := PMode;
  P.Speed := PSpeed;
  var WasPlaying := P.Status <> PsmfStatusStandby;
  if (SeekPack <> P.SeekPack) or (SeekFrame <> P.FirstFrame) then
    Restart := True;
  P.SeekPack := SeekPack;
  P.FirstFrame := SeekFrame;
  if Restart then
    P.StartPlayback;
  P.Status := PsmfStatusPlaying;
  // Restarting a running player waits for its threads.
  if WasPlaying then
    Delay(500, 0)
  else
    FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerStop;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or ((P.Status <> PsmfStatusPlaying) and (P.Status <> PsmfStatusFinished)) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  P.StopPlayback;
  P.Status := PsmfStatusStandby;
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerBreak;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if P = nil then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  // Ends the wait for the next picture: it is due one vblank earlier.
  if (P.Shown >= 0) and (P.NextDue < MaxInt) and (P.NextDue > P.Updates) then
    Dec(P.NextDue);
  FHLE.Result(0);
end;

procedure TPSPPsmf.Finish(P: TPSPPsmfPlayer);
begin
  P.PendingFinish := False;
  if P.Status <> PsmfStatusPlaying then
    Exit;
  if P.Loop and not P.Starved then
    P.StartPlayback
  else
    P.Status := PsmfStatusFinished;
end;

procedure TPSPPsmf.ThreadWork(P: TPSPPsmfPlayer);
begin
  // The player's thread runs at its own priority: at once if it beats the
  // caller, otherwise when the caller next waits.
  var T := FKernel.Current;
  if (T = nil) or (P.Priority < T.Priority) then
  begin
    Finish(P);
    Exit;
  end;
  if not P.PendingFinish then
  begin
    P.PendingFinish := True;
    P.DeferNow := FKernel.Scheduler.Now;
    P.DeferClocks := T.RunClocks;
  end;
end;

procedure TPSPPsmf.CatchUp(P: TPSPPsmfPlayer);
begin
  if not P.PendingFinish then
    Exit;
  var T := FKernel.Current;
  if T = nil then
  begin
    Finish(P);
    Exit;
  end;
  // Off the CPU since the work was queued: the player's thread had its turn.
  var Ran := (T.RunClocks - P.DeferClocks) * 1000 div FKernel.Scheduler.MHz;
  if FKernel.Scheduler.Now - P.DeferNow > Ran + 2000 then
    Finish(P);
end;

procedure TPSPPsmf.Yielding(P: TPSPPsmfPlayer);
begin
  if (P <> nil) and P.PendingFinish then
    Finish(P);
end;

procedure TPSPPsmf.CheckEnd(P: TPSPPsmfPlayer);
begin
  if P.Status <> PsmfStatusPlaying then
    Exit;
  if P.Starved then
  begin
    if P.Updates >= 6 then
      ThreadWork(P);
    Exit;
  end;
  // Two updates after the last picture was shown the movie is over.
  if (P.Shown >= 0) and P.StreamDone and (P.Ready.Count = 0) then
  begin
    Inc(P.AfterLast);
    if P.AfterLast >= 2 then
      ThreadWork(P);
  end;
end;

procedure TPSPPsmf.hPlayerUpdate;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or ((P.Status <> PsmfStatusPlaying) and (P.Status <> PsmfStatusFinished)) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  CatchUp(P);
  if P.Status = PsmfStatusPlaying then
  begin
    Inc(P.Updates);
    CheckEnd(P);
  end;
  FHLE.Result(0);
end;

procedure TPSPPsmf.WriteVideo(P: TPSPPsmfPlayer; Buffer: Cardinal; Width: Integer);
begin
  var Format := P.PixelMode;
  if Format < 0 then
    Format := PSPPixel8888;
  var Pic := P.ShownPic;
  var Bpp := PSPPixelBytes(Format);
  var Bytes := Cardinal((Pic.Height - 1) * Width + Pic.Width) * Cardinal(Bpp);
  var Dest := FMemory.Ptr(Buffer, Bytes);
  if Dest <> nil then
  begin
    PSPWritePicture(Pic, Dest, Width, Format);
    FMemory.Touched(Buffer, Bytes);
  end;
end;

function TPSPPsmf.AdvanceVideo(P: TPSPPsmfPlayer): Boolean;
begin
  // At most one new picture per call, once the clock reaches it.
  Result := False;
  if (P.Status <> PsmfStatusPlaying) or P.Starved or (P.Updates < P.NextDue) then
    Exit;
  var Pic: TPSPPicture;
  if not P.NextPicture(Pic) then
    Exit;
  var First := P.Shown < 0;
  if First then
    P.Shown := P.FirstFrame
  else
    Inc(P.Shown);
  P.ShownPic := Pic;
  P.AfterLast := 0;
  if First then
    P.NextDue := 8
  else
    case P.Mode of
      0, 4, 5:
        Inc(P.NextDue, 2);
      1:
        Inc(P.NextDue, 6);
    else
      P.NextDue := MaxInt;
    end;
  Result := True;
end;

procedure TPSPPsmf.hPlayerGetVideoData;
begin
  var P := PlayerOf(FHLE.Arg(0));
  var V := FHLE.Arg(1);
  if (P = nil) or ((P.Status <> PsmfStatusPlaying) and (P.Status <> PsmfStatusFinished)) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  CatchUp(P);
  var Fresh := AdvanceVideo(P);
  if P.Shown < 0 then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_NO_MORE_DATA);
    Exit;
  end;
  var Width := Integer(FMemory.Read32(V));
  var Buffer := FMemory.Read32(V + 4);
  if Width < 0 then
  begin
    FHLE.Result($80000023);
    Exit;
  end;
  if Width = 0 then
    Width := 512;
  Width := Width and not 1;
  if Width < P.ShownPic.Width then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  if Buffer = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER);
    Exit;
  end;
  FMemory.Write32(V + 8, Cardinal(P.Shown * FrameTicks));
  // The picture is converted again when it is new, when no vblank went by
  // since the last call, or after a play mode change.
  var Write := Fresh or P.ForceWrite or (P.Status = PsmfStatusFinished) or (P.LastVideoUpdates = P.Updates);
  P.LastVideoUpdates := P.Updates;
  P.ForceWrite := False;
  if Write then
    WriteVideo(P, Buffer, Width);
  Yielding(P);
  Delay(500, 0);
end;

procedure TPSPPsmf.hPlayerGetAudioData;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or ((P.Status <> PsmfStatusPlaying) and (P.Status <> PsmfStatusFinished)) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  // Audio runs a few frames ahead of the video clock (2048 samples = 4180 ticks).
  if (P.Status <> PsmfStatusPlaying) or P.Starved or (P.AudioQ = nil) or (P.Updates < 5) or (Int64(P.AudioFrames) *
    4180 > Int64(P.Updates - 5) * 1502 + 4 * 4180) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_NO_MORE_DATA);
    Exit;
  end;
  var Pcm: TArray<SmallInt>;
  if not P.NextAudio(Pcm) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_NO_MORE_DATA);
    Exit;
  end;
  var Dest := FHLE.Arg(1);
  if Dest <> 0 then
    FMemory.WriteBytes(Dest, Pcm[0], $2000);
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerGetCurrentStatus;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if P = nil then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  FHLE.Result(Cardinal(P.Status));
end;

procedure TPSPPsmf.hPlayerGetCurrentPts;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or (P.Status < PsmfStatusStandby) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  if P.Shown < 0 then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_NO_MORE_DATA);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(P.Shown * FrameTicks));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerConfigPlayer;
begin
  var P := PlayerOf(FHLE.Arg(0));
  var Key := FHLE.ArgInt(1);
  var Value := FHLE.ArgInt(2);
  if P = nil then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  case Key of
    0:
      begin
        if (Value <> 0) and (Value <> 1) then
        begin
          FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
          Exit;
        end;
        P.Loop := Value = 0;
      end;
    1:
      begin
        if (Value < -1) or (Value > 3) then
        begin
          FHLE.Result(ERROR_PSMFPLAYER_INVALID_PARAM);
          Exit;
        end;
        P.PixelMode := Value;
      end;
  else
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_CONFIG);
    Exit;
  end;
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerGetCurrentVideoStream;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or (P.Status < PsmfStatusStandby) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  var Codec := -1;
  var Num := -1;
  if P.Status <> PsmfStatusStandby then
  begin
    Codec := P.VideoCodec;
    Num := P.VideoNum;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(Codec));
  FMemory.Write32(FHLE.Arg(2), Cardinal(Num));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerGetCurrentAudioStream;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or (P.Status < PsmfStatusStandby) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  var Codec := -1;
  var Num := -1;
  if P.Status <> PsmfStatusStandby then
  begin
    Codec := P.AudioCodec;
    Num := P.AudioNum;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(Codec));
  FMemory.Write32(FHLE.Arg(2), Cardinal(Num));
  FHLE.Result(0);
end;

procedure TPSPPsmf.SelectStream(Kind: Integer; Specific: Boolean);
begin
  var P := PlayerOf(FHLE.Arg(0));
  if (P = nil) or (P.Status <> PsmfStatusPlaying) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  var Current := P.VideoNum;
  if Kind <> PSMFKindAvc then
    Current := P.AudioNum;
  // Only another stream that is in the header and has data in the movie.
  var Usable :=
    function(Num: Integer): Boolean
    begin
      var I := P.Header.Find(Kind, Num);
      Result := (I >= 0) and (Num <> Current) and PSMFStreamPresent(P.Data, P.StreamStart, P.Header.Streams[I].StreamId,
        P.Header.Streams[I].PrivateId);
    end;
  var Num := -1;
  if Specific then
  begin
    var Codec := FHLE.ArgInt(1);
    var Ok := ((Kind = PSMFKindAvc) and ((Codec = 0) or (Codec = $0E))) or ((Kind <> PSMFKindAvc) and
      ((Codec = 1) or (Codec = $0F)));
    if Ok and Usable(FHLE.ArgInt(2)) then
      Num := FHLE.ArgInt(2);
  end
  else
  begin
    var Count := P.Header.Count(Kind);
    for var K := 1 to Count - 1 do
      if Usable((Current + K) mod Count) then
      begin
        Num := (Current + K) mod Count;
        Break;
      end;
  end;
  if Num < 0 then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STREAM);
    Exit;
  end;
  if Kind = PSMFKindAvc then
  begin
    P.VideoNum := Num;
    P.StartPlayback;
  end
  else
  begin
    P.AudioNum := Num;
    if P.AudioQ <> nil then
      P.Demux.RemoveStream(P.AudioQ);
    var I := P.Header.Find(Kind, Num);
    P.AudioQ := P.Demux.AddStream(PSMFKindAtrac, $BD, P.Header.Streams[I].PrivateId);
    FreeAndNil(P.Atrac);
  end;
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerSelectVideo;
begin
  SelectStream(PSMFKindAvc, False);
end;

procedure TPSPPsmf.hPlayerSelectAudio;
begin
  SelectStream(PSMFKindAtrac, False);
end;

procedure TPSPPsmf.hPlayerSelectSpecificVideo;
begin
  SelectStream(PSMFKindAvc, True);
end;

procedure TPSPPsmf.hPlayerSelectSpecificAudio;
begin
  SelectStream(PSMFKindAtrac, True);
end;

procedure TPSPPsmf.hPlayerGetCurrentPlayMode;
begin
  var P := PlayerOf(FHLE.Arg(0));
  if P = nil then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(P.Mode));
  FMemory.Write32(FHLE.Arg(2), Cardinal(P.Speed));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hPlayerChangePlayMode;
begin
  var P := PlayerOf(FHLE.Arg(0));
  var M := FHLE.ArgInt(1);
  if (P = nil) or ((P.Status <> PsmfStatusPlaying) and (P.Status <> PsmfStatusFinished)) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_STATUS);
    Exit;
  end;
  P.ForceWrite := True;
  if (M = 4) or (M = 5) then
  begin
    // Fast forward and rewind jump between entry points.
    var V := P.Header.Find(PSMFKindAvc, P.VideoNum);
    if (V < 0) or (Length(P.Header.Streams[V].EP) = 0) then
    begin
      FHLE.Result(ERROR_PSMFPLAYER_INVALID_STREAM);
      Exit;
    end;
    FHLE.Unimplemented('fast forward and rewind');
  end
  else if (M < 0) or (M > 3) then
  begin
    FHLE.Result(ERROR_PSMFPLAYER_INVALID_CONFIG);
    Exit;
  end;
  if (M in [0, 1, 4, 5]) and (P.NextDue = MaxInt) then
    P.NextDue := P.Updates + 2;
  P.Mode := M;
  FHLE.Result(0);
end;

{ scePsmf }

function ReadHeader(Memory: TPSPMemory; Address: Cardinal; out Header: TPSPPsmfHeader): Cardinal;
begin
  var Data: TBytes;
  SetLength(Data, PSMFPacketSize);
  Memory.ReadBytes(Address, Data[0], PSMFPacketSize);
  var Size := PSMFBE32(@Data[8]);
  if (Size > PSMFPacketSize) and (Size < $100000) and Memory.Valid(Address, Size) then
  begin
    SetLength(Data, Size);
    Memory.ReadBytes(Address, Data[0], Size);
  end;
  Result := Header.Parse(Data);
end;

procedure TPSPPsmf.hSetPsmf;
begin
  var Ptr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  var H: TPSPPsmfHeader;
  if ReadHeader(FMemory, Buf, H) <> 0 then
  begin
    FHLE.Result(ERROR_PSMF_BAD_VERSION);
    Exit;
  end;
  var D := PsmfOf(Ptr);
  if D = nil then
  begin
    D := TPSPPsmfData.Create;
    D.Address := Ptr;
    FPsmfs.Add(D);
  end;
  D.Header := H;
  D.Current := 0;
  // The struct keeps the version, header size, stream size and the header address.
  FMemory.Write32(Ptr, H.Version);
  FMemory.Write32(Ptr + 4, H.HeaderSize);
  FMemory.Write32(Ptr + 8, H.StreamSize);
  FMemory.Write32(Ptr + 12, 0);
  FMemory.Write32(Ptr + 16, Buf);
  FHLE.Result(0);
end;

procedure TPSPPsmf.hVerifyPsmf;
begin
  var H: TPSPPsmfHeader;
  if ReadHeader(FMemory, FHLE.Arg(0), H) <> 0 then
    FHLE.Result(ERROR_PSMF_INVALID_PSMF)
  else
    FHLE.Result(0);
end;

procedure TPSPPsmf.hQueryStreamOffset;
begin
  var Buf := FHLE.Arg(0);
  var Out_ := FHLE.Arg(1);
  var B: array[0..15] of Byte;
  FMemory.ReadBytes(Buf, B, 16);
  if (B[0] <> Ord('P')) or (B[1] <> Ord('S')) or (B[2] <> Ord('M')) or (B[3] <> Ord('F')) then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_PSMF);
    Exit;
  end;
  FMemory.Write32(Out_, PSMFBE32(@B[8]));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hQueryStreamSize;
begin
  var Buf := FHLE.Arg(0);
  var Out_ := FHLE.Arg(1);
  var B: array[0..15] of Byte;
  FMemory.ReadBytes(Buf, B, 16);
  if (B[0] <> Ord('P')) or (B[1] <> Ord('S')) or (B[2] <> Ord('M')) or (B[3] <> Ord('F')) then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_PSMF);
    Exit;
  end;
  FMemory.Write32(Out_, PSMFBE32(@B[12]));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetPsmfVersion;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FHLE.Result(D.Header.Version);
end;

procedure TPSPPsmf.hGetHeaderSize;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), D.Header.HeaderSize);
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetStreamSize;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), D.Header.StreamSize);
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetPresentationStartTime;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(D.Header.StartTime));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetPresentationEndTime;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(D.Header.EndTime));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetNumberOfStreams;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FHLE.Result(Cardinal(Length(D.Header.Streams)));
end;

function PsmfTypeKind(T: Integer): Integer;
begin
  case T of
    0:
      Result := PSMFKindAvc;
    1:
      Result := PSMFKindAtrac;
    2:
      Result := PSMFKindPcm;
  else
    Result := -1;
  end;
end;

procedure TPSPPsmf.hGetNumberOfSpecificStreams;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  var T := FHLE.ArgInt(1);
  if T = 15 then
  begin
    FHLE.Result(Cardinal(D.Header.Count(PSMFKindAtrac) + D.Header.Count(PSMFKindPcm)));
    Exit;
  end;
  var K := PsmfTypeKind(T);
  if K < 0 then
    FHLE.Result(0)
  else
    FHLE.Result(Cardinal(D.Header.Count(K)));
end;

procedure TPSPPsmf.hSpecifyStream;
begin
  var D := PsmfOf(FHLE.Arg(0));
  var N := FHLE.ArgInt(1);
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  if (N < 0) or (N >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_ID);
    Exit;
  end;
  D.Current := N;
  FHLE.Result(0);
end;

procedure TPSPPsmf.hSpecifyStreamWithStreamType;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  var K := PsmfTypeKind(FHLE.ArgInt(1));
  var I := D.Header.Find(K, FHLE.ArgInt(2));
  if I < 0 then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_ID);
    Exit;
  end;
  D.Current := I;
  FHLE.Result(0);
end;

procedure TPSPPsmf.hSpecifyStreamWithStreamTypeNumber;
begin
  hSpecifyStreamWithStreamType;
end;

procedure TPSPPsmf.hGetCurrentStreamType;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  var S := D.Header.Streams[D.Current];
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(S.Kind));
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(S.Number));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetCurrentStreamNumber;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if D = nil then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FHLE.Result(Cardinal(D.Current));
end;

procedure TPSPPsmf.hGetVideoInfo;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) or (D.Header.Streams[D.Current].Kind <> PSMFKindAvc) then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_ID);
    Exit;
  end;
  var S := D.Header.Streams[D.Current];
  FMemory.Write32(FHLE.Arg(1), Cardinal(S.Width));
  FMemory.Write32(FHLE.Arg(1) + 4, Cardinal(S.Height));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetAudioInfo;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) or (D.Header.Streams[D.Current].Kind = PSMFKindAvc) then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_ID);
    Exit;
  end;
  var S := D.Header.Streams[D.Current];
  FMemory.Write32(FHLE.Arg(1), Cardinal(S.Channels));
  FMemory.Write32(FHLE.Arg(1) + 4, Cardinal(S.Frequency));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetNumberOfEPentries;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  FHLE.Result(Cardinal(Length(D.Header.Streams[D.Current].EP)));
end;

procedure TPSPPsmf.hCheckEPMap;
begin
  var D := PsmfOf(FHLE.Arg(0));
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  if Length(D.Header.Streams[D.Current].EP) = 0 then
    FHLE.Result(ERROR_PSMF_NOT_FOUND)
  else
    FHLE.Result(0);
end;

procedure TPSPPsmf.hGetEPWithId;
begin
  var D := PsmfOf(FHLE.Arg(0));
  var Id := FHLE.ArgInt(1);
  var Out_ := FHLE.Arg(2);
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  var EP := D.Header.Streams[D.Current].EP;
  if (Id < 0) or (Id >= Length(EP)) then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_ID);
    Exit;
  end;
  FMemory.Write32(Out_, Cardinal(EP[Id].Pts));
  FMemory.Write32(Out_ + 4, EP[Id].Offset * PSMFPacketSize);
  FMemory.Write32(Out_ + 8, Cardinal(EP[Id].Index));
  FMemory.Write32(Out_ + 12, Cardinal(EP[Id].PicOffset));
  FHLE.Result(0);
end;

function EPFor(const EP: TArray<TPSPPsmfEntry>; Ts: Int64): Integer;
begin
  Result := -1;
  for var I := 0 to High(EP) do
    if EP[I].Pts <= Ts then
      Result := I
    else
      Break;
end;

procedure TPSPPsmf.hGetEPWithTimestamp;
begin
  var D := PsmfOf(FHLE.Arg(0));
  var Ts := Int64(FHLE.Arg(1));
  var Out_ := FHLE.Arg(2);
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  var EP := D.Header.Streams[D.Current].EP;
  if Ts < D.Header.StartTime then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_TIMESTAMP);
    Exit;
  end;
  var I := EPFor(EP, Ts);
  if I < 0 then
  begin
    FHLE.Result(ERROR_PSMF_NOT_FOUND);
    Exit;
  end;
  FMemory.Write32(Out_, Cardinal(EP[I].Pts));
  FMemory.Write32(Out_ + 4, EP[I].Offset * PSMFPacketSize);
  FMemory.Write32(Out_ + 8, Cardinal(EP[I].Index));
  FMemory.Write32(Out_ + 12, Cardinal(EP[I].PicOffset));
  FHLE.Result(0);
end;

procedure TPSPPsmf.hGetEPidWithTimestamp;
begin
  var D := PsmfOf(FHLE.Arg(0));
  var Ts := Int64(FHLE.Arg(1));
  if (D = nil) or (D.Current >= Length(D.Header.Streams)) then
  begin
    FHLE.Result(ERROR_PSMF_NOT_INITIALIZED);
    Exit;
  end;
  if Ts < D.Header.StartTime then
  begin
    FHLE.Result(ERROR_PSMF_INVALID_TIMESTAMP);
    Exit;
  end;
  var I := EPFor(D.Header.Streams[D.Current].EP, Ts);
  if I < 0 then
    FHLE.Result(ERROR_PSMF_NOT_FOUND)
  else
    FHLE.Result(Cardinal(I));
end;

initialization
  RegisterPSPService(TPSPPsmf);

end.

