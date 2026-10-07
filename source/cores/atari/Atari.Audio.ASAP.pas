unit Atari.Audio.ASAP;

interface

uses
  System.SysUtils, System.Math;

type
  TCpu6502 = class;

  TPokeyChannel = class;

  TPokey = class;

  TPokeyPair = class;

  TASAPInfo = class;

  TASAP = class;

  TASAPModuleType = Integer;

  TNmiStatus = Integer;

  TASAPSampleFormat = Integer;

  TCpu6502 = class
  public
    asap: TASAP;
    memory: TArray<Byte>;
    cycle: Integer;
    pc: Integer;
    a: Integer;
    x: Integer;
    y: Integer;
    s: Integer;
    nz: Integer;
    c: Integer;
    vdi: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TPokeyChannel = class
  public
    audf: Integer;
    audc: Integer;
    periodCycles: Integer;
    tickCycle: Integer;
    timerCycle: Integer;
    mute: Integer;
    output: Integer;
    delta: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TPokey = class
  public
    channels: TArray<TPokeyChannel>;
    audctl: Integer;
    skctl: Integer;
    irqst: Integer;
    init: Boolean;
    divCycles: Integer;
    reloadCycles1: Integer;
    reloadCycles3: Integer;
    polyIndex: Integer;
    deltaBufferLength: Integer;
    deltaBuffer: TArray<Integer>;
    sumDACInputs: Integer;
    sumDACOutputs: Integer;
    iirRate: Integer;
    iirAcc: Integer;
    trailing: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TPokeyPair = class
  public
    poly9Lookup: TArray<Byte>;
    poly17Lookup: TArray<Byte>;
    extraPokeyMask: Integer;
    basePokey: TPokey;
    extraPokey: TPokey;
    sampleRate: Integer;
    sincLookup: TArray<TArray<SmallInt>>;
    sampleFactor: Integer;
    sampleOffset: Integer;
    readySamplesStart: Integer;
    readySamplesEnd: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TASAPInfo = class
  public
    filename: AnsiString;
    author: AnsiString;
    title: AnsiString;
    date: AnsiString;
    channels: Integer;
    songs: Integer;
    defaultSong: Integer;
    durations: TArray<Integer>;
    loops: TArray<Boolean>;
    ntsc: Boolean;
    kind: TASAPModuleType;
    fastplay: Integer;
    music: Integer;
    init: Integer;
    player: Integer;
    covoxAddr: Integer;
    headerLen: Integer;
    songPos: TArray<Byte>;
    constructor Create;
    destructor Destroy; override;
  end;

  TASAP = class
  public
    nextEventCycle: Integer;
    cpu: TCpu6502;
    nextScanlineCycle: Integer;
    nmist: TNmiStatus;
    consol: Integer;
    covox: TArray<Byte>;
    pokeys: TPokeyPair;
    moduleInfo: TASAPInfo;
    nextPlayerCycle: Integer;
    tmcPerFrameCounter: Integer;
    currentSong: Integer;
    currentDuration: Integer;
    blocksPlayed: Integer;
    silenceCycles: Integer;
    silenceCyclesCounter: Integer;
    gtiaOrCovoxPlayedThisFrame: Boolean;
    currentSampleRate: Integer;
    mptSamplesPage, mptSamplesCurrentAddress: Integer;
    mptSamples15kHz, mptSamplesSecondNibble: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

const
  ASAPSampleFormat_U8 = 0;
  ASAPSampleFormat_S16_L_E = 1;
  ASAPSampleFormat_S16_B_E = 2;
  NmiStatus_RESET = 0;
  NmiStatus_ON_V_BLANK = 1;
  NmiStatus_WAS_V_BLANK = 2;
  ASAPModuleType_SAP_B = 0;
  ASAPModuleType_SAP_C = 1;
  ASAPModuleType_SAP_D = 2;
  ASAPModuleType_SAP_S = 3;
  ASAPModuleType_CMC = 4;
  ASAPModuleType_CM3 = 5;
  ASAPModuleType_CMR = 6;
  ASAPModuleType_CMS = 7;
  ASAPModuleType_DLT = 8;
  ASAPModuleType_MPT = 9;
  ASAPModuleType_RMT = 10;
  ASAPModuleType_TMC = 11;
  ASAPModuleType_TM2 = 12;
  ASAPModuleType_FC = 13;
  ASAPModuleType_MD1 = 14;
  ASAPModuleType_D15 = 15;
  Pokey_COMPRESSED_SUMS: array[0..60] of SmallInt = (0, 35, 73, 111, 149, 189, 228, 266, 304, 342, 379, 415, 450, 484, 516, 546, 575, 602, 628, 652, 674, 695, 715, 733, 750, 766, 782, 796, 809, 822, 834, 846, 856, 867, 876, 886, 894, 903, 911, 918, 926, 933, 939, 946, 952, 958, 963, 969, 974, 979, 984, 988, 993, 997, 1001, 1005, 1009, 1013, 1016, 1019, 1023);

procedure ASAPInfo_AddSong(ctx: TASAPInfo; playerCalls: Integer);

procedure ASAPInfo_Construct(ctx: TASAPInfo);

function ASAPInfo_GetChannels(ctx: TASAPInfo): Integer;

function ASAPInfo_GetCovoxAddress(ctx: TASAPInfo): Integer;

function ASAPInfo_GetInitAddress(ctx: TASAPInfo): Integer;

function ASAPInfo_GetMusicAddress(ctx: TASAPInfo): Integer;

function ASAPInfo_GetPlayerRateScanlines(ctx: TASAPInfo): Integer;

function ASAPInfo_GetRmtInstrumentFrames(module: TBytes; instrument: Integer; volume: Integer; volumeFrame: Integer; onExtraPokey: Boolean): Integer;

function ASAPInfo_GetSongs(ctx: TASAPInfo): Integer;

function ASAPInfo_GetWord(dataArray: TBytes; i: Integer): Integer;

function ASAPInfo_IsNtsc(ctx: TASAPInfo): Boolean;

function ASAPInfo_IsValidChar(c: Integer): Boolean;

function ASAPInfo_ParseModule(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;

function ASAPInfo_ParseRmt(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;

procedure ASAPInfo_ParseRmtSong(ctx: TASAPInfo; module: TBytes; globalSeen: TArray<Boolean>; songLen: Integer; posShift: Integer; pos: Integer);

function ASAPInfo_ValidateRmt(module: TBytes; moduleLen: Integer): Boolean;

procedure ASAP_Call6502(ctx: TASAP; addr: Integer);

procedure ASAP_Call6502Player(ctx: TASAP);

procedure ASAP_Construct(ctx: TASAP);

function ASAP_Do6502Frame(ctx: TASAP): Integer;

function ASAP_Do6502Init(ctx: TASAP; pc: Integer; a: Integer; x: Integer; y: Integer): Boolean;

function ASAP_DoFrame(ctx: TASAP): Integer;

function ASAP_Generate(ctx: TASAP; buffer: TBytes; bufferLen: Integer; format: TASAPSampleFormat): Integer;

function ASAP_GenerateAt(ctx: TASAP; buffer: TBytes; bufferOffset: Integer; bufferLen: Integer; format: TASAPSampleFormat): Integer;

procedure ASAP_HandleEvent(ctx: TASAP);

function ASAP_IsIrq(ctx: TASAP): Boolean;

function ASAP_MillisecondsToBlocks(ctx: TASAP; milliseconds: Integer): Integer;

procedure ASAP_MutePokeyChannels(ctx: TASAP; mask: Integer);

function ASAP_PeekHardware(ctx: TASAP; addr: Integer): Integer;

function ASAP_PlaySong(ctx: TASAP; song: Integer; duration: Integer): Boolean;

procedure ASAP_PokeHardware(ctx: TASAP; addr: Integer; data: Integer);

procedure Cpu6502_AddWithCarry(ctx: TCpu6502; data: Integer);

function Cpu6502_ArithmeticShiftLeft(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_CheckIrq(ctx: TCpu6502);

function Cpu6502_Decrement(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_DoFrame(ctx: TCpu6502; cycleLimit: Integer);

procedure Cpu6502_ExecuteIrq(ctx: TCpu6502; b: Integer);

function Cpu6502_Increment(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_LogicalShiftRight(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_Peek(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_PeekReadModifyWrite(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_Poke(ctx: TCpu6502; addr: Integer; data: Integer);

function Cpu6502_Pull(ctx: TCpu6502): Integer;

procedure Cpu6502_PullFlags(ctx: TCpu6502);

procedure Cpu6502_Push(ctx: TCpu6502; data: Integer);

procedure Cpu6502_PushFlags(ctx: TCpu6502; b: Integer);

procedure Cpu6502_PushPc(ctx: TCpu6502);

procedure Cpu6502_Reset(ctx: TCpu6502);

function Cpu6502_RotateLeft(ctx: TCpu6502; addr: Integer): Integer;

function Cpu6502_RotateRight(ctx: TCpu6502; addr: Integer): Integer;

procedure Cpu6502_Shx(ctx: TCpu6502; addr: Integer; data: Integer);

procedure Cpu6502_SubtractWithCarry(ctx: TCpu6502; data: Integer);

procedure PokeyChannel_DoStimer(ctx: TPokeyChannel; cycle: Integer);

procedure PokeyChannel_DoTick(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer; ch: Integer);

procedure PokeyChannel_EndFrame(ctx: TPokeyChannel; cycle: Integer);

procedure PokeyChannel_Initialize(ctx: TPokeyChannel);

procedure PokeyChannel_SetAudc(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; data: Integer; cycle: Integer);

procedure PokeyChannel_SetMute(ctx: TPokeyChannel; enable: Boolean; mask: Integer; cycle: Integer);

procedure PokeyChannel_Slope(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer);

procedure PokeyPair_Construct(ctx: TPokeyPair);

function PokeyPair_EndFrame(ctx: TPokeyPair; cycle: Integer): Integer;

function PokeyPair_Generate(ctx: TPokeyPair; buffer: TBytes; bufferOffset: Integer; blocks: Integer; format: TASAPSampleFormat): Integer;

function PokeyPair_GetSampleFactor(ctx: TPokeyPair; clock: Integer): Integer;

procedure PokeyPair_Initialize(ctx: TPokeyPair; ntsc: Boolean; stereo: Boolean; sampleRate: Integer);

function PokeyPair_IsSilent(ctx: TPokeyPair): Boolean;

function PokeyPair_Peek(ctx: TPokeyPair; addr: Integer; cycle: Integer): Integer;

function PokeyPair_Poke(ctx: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;

procedure PokeyPair_StartFrame(ctx: TPokeyPair);

procedure Pokey_AccumulateTrailing(ctx: TPokey; i: Integer);

procedure Pokey_AddDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);

procedure Pokey_AddExternalDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);

function Pokey_CheckIrq(ctx: TPokey; cycle: Integer; nextEventCycle: Integer): Integer;

procedure Pokey_Construct(ctx: TPokey);

procedure Pokey_EndFrame(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer);

procedure Pokey_GenerateUntilCycle(ctx: TPokey; pokeys: TPokeyPair; cycleLimit: Integer);

procedure Pokey_InitMute(ctx: TPokey; cycle: Integer);

procedure Pokey_Initialize(ctx: TPokey; sampleRate: Integer);

function Pokey_IsSilent(ctx: TPokey): Boolean;

procedure Pokey_Mute(ctx: TPokey; mask: Integer);

function Pokey_Poke(ctx: TPokey; pokeys: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;

procedure Pokey_StartFrame(ctx: TPokey);

function Pokey_StoreSample(ctx: TPokey; buffer: TBytes; bufferOffset: Integer; i: Integer; format: TASAPSampleFormat): Integer;

implementation

const
  OpcodeCycles: array[0..255] of Byte = (
    7, 6, 2, 8, 3, 3, 5, 5, 3, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    6, 6, 2, 8, 3, 3, 5, 5, 4, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    6, 6, 2, 8, 3, 3, 5, 5, 3, 2, 2, 2, 3, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    6, 6, 2, 8, 3, 3, 5, 5, 4, 2, 2, 2, 5, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,
    2, 6, 2, 6, 4, 4, 4, 4, 2, 5, 2, 5, 5, 5, 5, 5,
    2, 6, 2, 6, 3, 3, 3, 3, 2, 2, 2, 2, 4, 4, 4, 4,
    2, 5, 2, 5, 4, 4, 4, 4, 2, 4, 2, 4, 4, 4, 4, 4,
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7,
    2, 6, 2, 8, 3, 3, 5, 5, 2, 2, 2, 2, 4, 4, 6, 6,
    2, 5, 2, 8, 4, 4, 6, 6, 2, 4, 2, 7, 4, 4, 7, 7);


// One shared work limit protects both RMT analysis paths from cyclic commands.
procedure CheckRmtWorkLimit(var Steps: Integer); inline;
begin
  Inc(Steps);
  if Steps > 8000000 then
    raise EArgumentException.Create('RMT analysis exceeds work limit');
end;

function BytesText(const Data: TBytes; Count: Integer): AnsiString;
begin
  SetLength(Result, Count);
  for var I := 0 to Count - 1 do
    Result[I + 1] := AnsiChar(Data[I]);
end;

function S32(Value: Int64): Integer;
begin
  Value := Value and $FFFFFFFF;
  if Value >= $80000000 then
    Dec(Value, $100000000);
  Result := Value;
end;

function U8(Value: Int64): Byte;
begin
  Result := Value and 255;
end;

function S16(Value: Int64): SmallInt;
begin
  Value := Value and 65535;
  if Value >= 32768 then
    Dec(Value, 65536);
  Result := Value;
end;

function Sar32(Value: Int64; Bits: Integer): Integer;
begin
  Bits := Bits and 31;
  Value := S32(Value);
  if Value >= 0 then
    Result := Value shr Bits
  else
    Result := -((-Value + (Int64(1) shl Bits) - 1) shr Bits);
end;

constructor TCpu6502.Create;
begin
  inherited;
  SetLength(memory, 65536);
end;

destructor TCpu6502.Destroy;
begin
  inherited;
end;

constructor TPokeyChannel.Create;
begin
  inherited;
end;

destructor TPokeyChannel.Destroy;
begin
  inherited;
end;

constructor TPokey.Create;
begin
  inherited;
  SetLength(channels, 4);
  for var i := 0 to High(channels) do
    channels[i] := TPokeyChannel.Create;
end;

destructor TPokey.Destroy;
begin
  for var i := 0 to High(channels) do
    channels[i].Free;
  inherited;
end;

constructor TPokeyPair.Create;
begin
  inherited;
  SetLength(poly9Lookup, 511);
  SetLength(poly17Lookup, 16385);
  basePokey := TPokey.Create;
  extraPokey := TPokey.Create;
  SetLength(sincLookup, 1024, 32);
end;

destructor TPokeyPair.Destroy;
begin
  basePokey.Free;
  extraPokey.Free;
  inherited;
end;

constructor TASAPInfo.Create;
begin
  inherited;
  SetLength(durations, 32);
  SetLength(loops, 32);
  SetLength(songPos, 32);
end;

destructor TASAPInfo.Destroy;
begin
  inherited;
end;

constructor TASAP.Create;
begin
  inherited;
  cpu := TCpu6502.Create;
  SetLength(covox, 4);
  pokeys := TPokeyPair.Create;
  moduleInfo := TASAPInfo.Create;
end;

destructor TASAP.Destroy;
begin
  cpu.Free;
  pokeys.Free;
  moduleInfo.Free;
  inherited;
end;

procedure ASAPInfo_AddSong(ctx: TASAPInfo; playerCalls: Integer);
var
  scanlines: Int64;
  songIndex1: Integer;
begin
  scanlines := S32(Int64(playerCalls) * ctx.fastplay);
  songIndex1 := ctx.songs;
  ctx.songs := S32(ctx.songs + 1);
  ctx.durations[songIndex1] := S32(((scanlines * 38000) div 591149));
end;

procedure ASAPInfo_Construct(ctx: TASAPInfo);
begin
  ctx.filename := '';
  ctx.author := '';
  ctx.title := '';
  ctx.date := '';
end;

function ASAPInfo_GetChannels(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.channels));
end;

function ASAPInfo_GetCovoxAddress(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.covoxAddr));
end;

function ASAPInfo_GetInitAddress(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.init));
end;

function ASAPInfo_GetMusicAddress(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.music));
end;

function ASAPInfo_GetPlayerRateScanlines(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.fastplay));
end;

function ASAPInfo_GetRmtInstrumentFrames(module: TBytes; instrument: Integer; volume: Integer; volumeFrame: Integer; onExtraPokey: Boolean): Integer;
var
  addrToOffset: Integer;
  perFrame: Integer;
  playerCall: Integer;
  playerCalls: Integer;
  index: Integer;
  indexEnd: Integer;
  indexLoop: Integer;
  volumeSlideDepth: Integer;
  volumeMin: Integer;
  RMT_VOLUME_SILENT: TArray<Byte>;
  vol: Integer;
  volumeSlide: Integer;
  silentLoop: Boolean;
begin
  var parseSteps := 0;
  addrToOffset := S32(Int64(ASAPInfo_GetWord(module, 2)) - 6);
  instrument := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, 14)) - addrToOffset)) + S32((Int64(instrument) shl (1 and 31))));
  if (module[S32(Int64(instrument) + 1)] = 0) then
  begin
    Exit(S32(0));
  end;
  instrument := S32(Int64(ASAPInfo_GetWord(module, instrument)) - addrToOffset);
  perFrame := S32(module[12]);
  playerCall := S32(Int64(volumeFrame) * perFrame);
  playerCalls := S32(playerCall);
  index := S32(Int64(S32(Int64(module[instrument]) + 1)) + S32(Int64(playerCall) * 3));
  indexEnd := S32(Int64(module[S32(Int64(instrument) + 2)]) + 3);
  indexLoop := S32(module[S32(Int64(instrument) + 3)]);
  if (indexLoop >= indexEnd) then
  begin
    Exit(S32(0));
  end;
  volumeSlideDepth := S32(module[S32(Int64(instrument) + 6)]);
  volumeMin := S32(module[S32(Int64(instrument) + 7)]);
  SetLength(RMT_VOLUME_SILENT, 16);
  RMT_VOLUME_SILENT[0] := 16;
  RMT_VOLUME_SILENT[1] := 8;
  RMT_VOLUME_SILENT[2] := 4;
  RMT_VOLUME_SILENT[3] := 3;
  RMT_VOLUME_SILENT[4] := 2;
  RMT_VOLUME_SILENT[5] := 2;
  RMT_VOLUME_SILENT[6] := 2;
  RMT_VOLUME_SILENT[7] := 2;
  RMT_VOLUME_SILENT[8] := 1;
  RMT_VOLUME_SILENT[9] := 1;
  RMT_VOLUME_SILENT[10] := 1;
  RMT_VOLUME_SILENT[11] := 1;
  RMT_VOLUME_SILENT[12] := 1;
  RMT_VOLUME_SILENT[13] := 1;
  RMT_VOLUME_SILENT[14] := 1;
  RMT_VOLUME_SILENT[15] := 1;
  if (index >= indexEnd) then
  begin
    index := S32(Int64((S32(Int64(index) - indexEnd) mod S32(Int64(indexEnd) - indexLoop))) + indexLoop);
  end
  else
  begin
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      vol := S32(module[S32(Int64(instrument) + index)]);
      if onExtraPokey then
      begin
        vol := S32(Sar32(vol, 4));
      end;
      if ((vol and 15) >= RMT_VOLUME_SILENT[volume]) then
      begin
        playerCalls := S32(Int64(playerCall) + 1);
      end;
      playerCall := S32(playerCall + 1);
      index := S32(Int64(index) + 3);
      if not ((index < indexEnd)) then
        Break;
    end;
  end;
  if (volumeSlideDepth = 0) then
  begin
    Exit(S32((playerCalls div perFrame)));
  end;
  volumeSlide := S32(128);
  silentLoop := False;
  while True do
  begin
    CheckRmtWorkLimit(parseSteps);
    if (index >= indexEnd) then
    begin
      if silentLoop then
      begin
        Break;
      end;
      silentLoop := True;
      index := S32(indexLoop);
    end;
    vol := S32(module[S32(Int64(instrument) + index)]);
    if onExtraPokey then
    begin
      vol := S32(Sar32(vol, 4));
    end;
    if ((vol and 15) >= RMT_VOLUME_SILENT[volume]) then
    begin
      playerCalls := S32(Int64(playerCall) + 1);
      silentLoop := False;
    end;
    playerCall := S32(playerCall + 1);
    index := S32(Int64(index) + 3);
    volumeSlide := S32(Int64(volumeSlide) - volumeSlideDepth);
    if (volumeSlide < 0) then
    begin
      volumeSlide := S32(Int64(volumeSlide) + 256);
      volume := S32(volume - 1);
      if (volume <= volumeMin) then
      begin
        Break;
      end;
    end;
  end;
  Exit(S32((playerCalls div perFrame)));
end;

function ASAPInfo_GetSongs(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.songs));
end;

function ASAPInfo_GetWord(dataArray: TBytes; i: Integer): Integer;
begin
  Exit(S32(Int64(dataArray[i]) + S32((Int64(dataArray[S32(Int64(i) + 1)]) shl (8 and 31)))));
end;

function ASAPInfo_IsNtsc(ctx: TASAPInfo): Boolean;
begin
  Exit(ctx.ntsc);
end;

function ASAPInfo_IsValidChar(c: Integer): Boolean;
begin
  Exit(((((c >= 32) and (c <= 124)) and (c <> 96)) and (c <> 123)));
end;

function ASAPInfo_ParseModule(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;
var
  musicLastByte: Integer;
  blockLen: Integer;
  infoAddr: Integer;
  infoLen: Integer;
begin
  if (((module[0] <> 255) or (module[1] <> 255)) and ((module[0] <> 0) or (module[1] <> 0))) then
  begin
    Exit(False);
  end;
  ctx.music := S32(ASAPInfo_GetWord(module, 2));
  musicLastByte := S32(ASAPInfo_GetWord(module, 4));
  if ((ctx.music <= 55295) and (musicLastByte >= 53248)) then
  begin
    Exit(False);
  end;
  blockLen := S32(Int64(S32(Int64(musicLastByte) + 1)) - ctx.music);
  if (S32(Int64(6) + blockLen) <> moduleLen) then
  begin
    if ((ctx.kind <> ASAPModuleType_RMT) or (S32(Int64(11) + blockLen) > moduleLen)) then
    begin
      Exit(False);
    end;
    infoAddr := S32(ASAPInfo_GetWord(module, S32(Int64(6) + blockLen)));
    if (infoAddr <> S32(Int64(ctx.music) + blockLen)) then
    begin
      Exit(False);
    end;
    infoLen := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, S32(Int64(8) + blockLen))) + 1)) - infoAddr);
    if (S32(Int64(S32(Int64(10) + blockLen)) + infoLen) <> moduleLen) then
    begin
      Exit(False);
    end;
  end;
  Exit(True);
end;

function ASAPInfo_ParseRmt(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;
var
  posShift: Integer;
  perFrame: Integer;
  blockLen: Integer;
  songLen: Integer;
  globalSeen: TArray<Boolean>;
  pos: Integer;
  title: TArray<Byte>;
  titleLen: Integer;
  c: Integer;
  conditionValue5: Integer;
begin
  if not (ASAPInfo_ValidateRmt(module, moduleLen)) then
  begin
    Exit(False);
  end;
  case module[9] of
    52:
      begin
        posShift := S32(2);
      end;
    56:
      begin
        ctx.channels := S32(2);
        posShift := S32(3);
      end;
  else
    begin
      Exit(False);
    end;
  end;
  perFrame := S32(module[12]);
  if ((perFrame < 1) or (perFrame > 4)) then
  begin
    Exit(False);
  end;
  ctx.kind := S32(ASAPModuleType_RMT);
  if not (ASAPInfo_ParseModule(ctx, module, moduleLen)) then
  begin
    Exit(False);
  end;
  blockLen := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, 4)) + 1)) - ctx.music);
  songLen := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, 4)) + 1)) - ASAPInfo_GetWord(module, 20));
  if (((posShift = 3) and ((songLen and 4) <> 0)) and (module[S32(Int64(S32(Int64(6) + blockLen)) - 4)] = 254)) then
  begin
    songLen := S32(Int64(songLen) + 4);
  end;
  songLen := S32(Sar32(songLen, posShift));
  if (songLen >= 256) then
  begin
    Exit(False);
  end;
  SetLength(globalSeen, 256);
  globalSeen[0] := False;
  ctx.songs := S32(0);
  pos := S32(0);
  while ((pos < songLen) and (ctx.songs < 32)) do
  begin
    if not (globalSeen[pos]) then
    begin
      ctx.songPos[ctx.songs] := U8(pos);
      ASAPInfo_ParseRmtSong(ctx, module, globalSeen, songLen, posShift, pos);
    end;
    pos := S32(pos + 1);
  end;
  ctx.fastplay := S32((312 div perFrame));
  ctx.player := S32(1536);
  if (ctx.songs = 0) then
  begin
    Exit(False);
  end;
  SetLength(title, 127);
  titleLen := S32(0);
  while ((titleLen < 127) and (S32(Int64(S32(Int64(10) + blockLen)) + titleLen) < moduleLen)) do
  begin
    c := S32(module[S32(Int64(S32(Int64(10) + blockLen)) + titleLen)]);
    if (c = 0) then
    begin
      Break;
    end;
    if ASAPInfo_IsValidChar(c) then
    begin
      conditionValue5 := c;
    end
    else
    begin
      conditionValue5 := 32;
    end;
    title[titleLen] := U8(conditionValue5);
    titleLen := S32(titleLen + 1);
  end;
  ctx.title := BytesText(title, titleLen);
  Exit(True);
end;

procedure ASAPInfo_ParseRmtSong(ctx: TASAPInfo; module: TBytes; globalSeen: TArray<Boolean>; songLen: Integer; posShift: Integer; pos: Integer);
var
  addrToOffset: Integer;
  tempo: Integer;
  frames: Integer;
  songOffset: Integer;
  patternLoOffset: Integer;
  patternHiOffset: Integer;
  seen: TArray<Byte>;
  patternBegin: TArray<Integer>;
  patternOffset: TArray<Integer>;
  blankRows: TArray<Integer>;
  instrumentNo: TArray<Integer>;
  instrumentFrame: TArray<Integer>;
  volumeValue: TArray<Integer>;
  volumeFrame: TArray<Integer>;
  ch: Integer;
  p: Integer;
  i: Integer;
  patternRows: Integer;
  patternByteOffset9: Integer;
  patternByteOffset10: Integer;
  patternByteOffset11: Integer;
  patternByteOffset12: Integer;
  instrumentFrames: Integer;
  frame: Integer;
begin
  var parseSteps := 0;
  addrToOffset := S32(Int64(ASAPInfo_GetWord(module, 2)) - 6);
  tempo := S32(module[11]);
  frames := S32(0);
  songOffset := S32(Int64(ASAPInfo_GetWord(module, 20)) - addrToOffset);
  patternLoOffset := S32(Int64(ASAPInfo_GetWord(module, 16)) - addrToOffset);
  patternHiOffset := S32(Int64(ASAPInfo_GetWord(module, 18)) - addrToOffset);
  SetLength(seen, 256);
  for var z := 0 to High(seen) do
    seen[z] := 0;
  SetLength(patternBegin, 8);
  SetLength(patternOffset, 8);
  SetLength(blankRows, 8);
  SetLength(instrumentNo, 8);
  for var z := 0 to High(instrumentNo) do
    instrumentNo[z] := 0;
  SetLength(instrumentFrame, 8);
  for var z := 0 to High(instrumentFrame) do
    instrumentFrame[z] := 0;
  SetLength(volumeValue, 8);
  for var z := 0 to High(volumeValue) do
    volumeValue[z] := 0;
  SetLength(volumeFrame, 8);
  for var z := 0 to High(volumeFrame) do
    volumeFrame[z] := 0;
  while True do
  begin
    CheckRmtWorkLimit(parseSteps);
    if not ((pos < songLen)) then
      Break;
    if (seen[pos] <> 0) then
    begin
      if (seen[pos] <> 1) then
      begin
        ctx.loops[ctx.songs] := True;
      end;
      Break;
    end;
    seen[pos] := U8(1);
    globalSeen[pos] := True;
    if (module[S32(Int64(songOffset) + S32((Int64(pos) shl (posShift and 31))))] = 254) then
    begin
      pos := S32(module[S32(Int64(S32(Int64(songOffset) + S32((Int64(pos) shl (posShift and 31))))) + 1)]);
      Continue;
    end;
    ch := S32(0);
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      if not ((ch < S32((Int64(1) shl (posShift and 31))))) then
        Break;
      p := S32(module[S32(Int64(S32(Int64(songOffset) + S32((Int64(pos) shl (posShift and 31))))) + ch)]);
      if (p = 255) then
      begin
        blankRows[ch] := S32(256);
      end
      else
      begin
        patternBegin[ch] := S32(Int64(S32(Int64(module[S32(Int64(patternLoOffset) + p)]) + S32((Int64(module[S32(Int64(patternHiOffset) + p)]) shl (8 and 31))))) - addrToOffset);
        patternOffset[ch] := S32(patternBegin[ch]);
        if (patternOffset[ch] < 0) then
        begin
          Exit;
        end;
        blankRows[ch] := S32(0);
      end;
      ch := S32(ch + 1);
    end;
    i := S32(0);
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      if not ((i < songLen)) then
        Break;
      if (seen[i] = 1) then
      begin
        seen[i] := U8(2);
      end;
      i := S32(i + 1);
    end;
    patternRows := S32(module[10]);
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      patternRows := S32(patternRows - 1);
      if not ((patternRows >= 0)) then
        Break;
      ch := S32(0);
      while True do
      begin
        CheckRmtWorkLimit(parseSteps);
        if not ((ch < S32((Int64(1) shl (posShift and 31))))) then
          Break;
        blankRows[ch] := S32(blankRows[ch] - 1);
        if (blankRows[ch] > 0) then
        begin
          Inc(ch);
          Continue;
        end;
        while True do
        begin
          CheckRmtWorkLimit(parseSteps);
          patternByteOffset9 := patternOffset[ch];
          patternOffset[ch] := S32(patternOffset[ch] + 1);
          i := S32(module[patternByteOffset9]);
          if ((i and 63) < 62) then
          begin
            patternByteOffset10 := patternOffset[ch];
            patternOffset[ch] := S32(patternOffset[ch] + 1);
            i := S32(Int64(i) + S32((Int64(module[patternByteOffset10]) shl (8 and 31))));
            if ((i and 63) <> 61) then
            begin
              instrumentNo[ch] := S32(Sar32(i, 10));
              instrumentFrame[ch] := S32(frames);
            end;
            volumeValue[ch] := S32((Sar32(i, 6) and 15));
            volumeFrame[ch] := S32(frames);
            Break;
          end;
          if (i = 62) then
          begin
            patternByteOffset11 := patternOffset[ch];
            patternOffset[ch] := S32(patternOffset[ch] + 1);
            blankRows[ch] := S32(module[patternByteOffset11]);
            Break;
          end;
          if ((i and 63) = 62) then
          begin
            blankRows[ch] := S32(Sar32(i, 6));
            Break;
          end;
          if ((i and 191) = 63) then
          begin
            patternByteOffset12 := patternOffset[ch];
            patternOffset[ch] := S32(patternOffset[ch] + 1);
            tempo := S32(module[patternByteOffset12]);
            Continue;
          end;
          if (i = 191) then
          begin
            patternOffset[ch] := S32(Int64(patternBegin[ch]) + module[patternOffset[ch]]);
            Continue;
          end;
          patternRows := S32((-1));
          Break;
        end;
        if (patternRows < 0) then
        begin
          Break;
        end;
        ch := S32(ch + 1);
      end;
      if (patternRows >= 0) then
      begin
        frames := S32(Int64(frames) + tempo);
      end;
    end;
    pos := S32(pos + 1);
  end;
  instrumentFrames := S32(0);
  ch := S32(0);
  while True do
  begin
    CheckRmtWorkLimit(parseSteps);
    if not ((ch < S32((Int64(1) shl (posShift and 31))))) then
      Break;
    frame := S32(instrumentFrame[ch]);
    frame := S32(Int64(frame) + ASAPInfo_GetRmtInstrumentFrames(module, instrumentNo[ch], volumeValue[ch], S32(Int64(volumeFrame[ch]) - frame), (ch >= 4)));
    if (instrumentFrames < frame) then
    begin
      instrumentFrames := S32(frame);
    end;
    ch := S32(ch + 1);
  end;
  if (frames > instrumentFrames) then
  begin
    if (S32(Int64(frames) - instrumentFrames) > 100) then
    begin
      ctx.loops[ctx.songs] := False;
    end;
    frames := S32(instrumentFrames);
  end;
  if (frames > 0) then
  begin
    ASAPInfo_AddSong(ctx, frames);
  end;
end;

function ASAPInfo_ValidateRmt(module: TBytes; moduleLen: Integer): Boolean;
begin
  if (moduleLen < 48) then
  begin
    Exit(False);
  end;
  if ((((module[6] <> 82) or (module[7] <> 77)) or (module[8] <> 84)) or (module[13] <> 1)) then
  begin
    Exit(False);
  end;
  Exit(True);
end;

procedure ASAP_Call6502(ctx: TASAP; addr: Integer);
begin
  ctx.cpu.memory[53760] := U8(32);
  ctx.cpu.memory[53761] := U8(addr);
  ctx.cpu.memory[53762] := U8(Sar32(addr, 8));
  ctx.cpu.memory[53763] := U8(210);
  ctx.cpu.pc := S32(53760);
end;

procedure ASAP_Call6502Player(ctx: TASAP);
var
  player: Integer;
  i: Integer;
begin
  player := S32(ctx.moduleInfo.player);
  case ctx.moduleInfo.kind of
    ASAPModuleType_SAP_B:
      begin
        ASAP_Call6502(ctx, player);
      end;
    ASAPModuleType_SAP_C, ASAPModuleType_CMC, ASAPModuleType_CM3, ASAPModuleType_CMR, ASAPModuleType_CMS:
      begin
        ASAP_Call6502(ctx, S32(Int64(player) + 6));
      end;
    ASAPModuleType_SAP_D, ASAPModuleType_MD1:
      begin
        if ctx.moduleInfo.kind = ASAPModuleType_MD1 then
          Inc(player, 3);
        if (player >= 0) then
        begin
          Cpu6502_PushPc(ctx.cpu);
          ctx.cpu.memory[53760] := U8(8);
          ctx.cpu.memory[53761] := U8(72);
          ctx.cpu.memory[53762] := U8(138);
          ctx.cpu.memory[53763] := U8(72);
          ctx.cpu.memory[53764] := U8(152);
          ctx.cpu.memory[53765] := U8(72);
          ctx.cpu.memory[53766] := U8(32);
          ctx.cpu.memory[53767] := U8(player);
          ctx.cpu.memory[53768] := U8(Sar32(player, 8));
          ctx.cpu.memory[53769] := U8(104);
          ctx.cpu.memory[53770] := U8(168);
          ctx.cpu.memory[53771] := U8(104);
          ctx.cpu.memory[53772] := U8(170);
          ctx.cpu.memory[53773] := U8(104);
          ctx.cpu.memory[53774] := U8(64);
          ctx.cpu.pc := S32(53760);
        end;
      end;
    ASAPModuleType_SAP_S:
      begin
        i := S32(Int64(ctx.cpu.memory[69]) - 1);
        ctx.cpu.memory[69] := U8(i);
        if (i = 0) then
        begin
          ctx.cpu.memory[45179] := U8(S32(Int64(ctx.cpu.memory[45179]) + 1));
        end;
      end;
    ASAPModuleType_DLT:
      begin
        ASAP_Call6502(ctx, S32(Int64(player) + 259));
      end;
    ASAPModuleType_MPT, ASAPModuleType_RMT, ASAPModuleType_TM2, ASAPModuleType_FC:
      begin
        ASAP_Call6502(ctx, S32(Int64(player) + 3));
      end;
    ASAPModuleType_D15:
      begin
        if (ctx.cpu.cycle >= 1254) and
          (ctx.mptSamplesCurrentAddress div 256 < ctx.cpu.memory[ctx.moduleInfo.music + 16 + ctx.currentSong]) then
        begin
          var Value := Integer(ctx.cpu.memory[ctx.mptSamplesCurrentAddress]);
          if ctx.mptSamplesSecondNibble then
          begin
            Inc(ctx.mptSamplesCurrentAddress);
            ctx.mptSamplesSecondNibble := False;
          end
          else
          begin
            Value := Value shr 4;
            ctx.mptSamplesSecondNibble := True;
          end;
          PokeyPair_Poke(ctx.pokeys, $D201, (Value and 15) or $F0, ctx.cpu.cycle);
        end;
      end;
    ASAPModuleType_TMC:
      begin
        ctx.tmcPerFrameCounter := S32(ctx.tmcPerFrameCounter - 1);
        if (ctx.tmcPerFrameCounter <= 0) then
        begin
          ctx.tmcPerFrameCounter := S32(ctx.cpu.memory[S32(Int64(ASAPInfo_GetMusicAddress(ctx.moduleInfo)) + 31)]);
          ASAP_Call6502(ctx, S32(Int64(player) + 3));
        end
        else
        begin
          ASAP_Call6502(ctx, S32(Int64(player) + 6));
        end;
      end;
  end;
end;

procedure ASAP_Construct(ctx: TASAP);
begin
  PokeyPair_Construct(ctx.pokeys);
  ASAPInfo_Construct(ctx.moduleInfo);
  ctx.currentSampleRate := S32(44100);
  ctx.silenceCycles := S32(0);
  ctx.cpu.asap := ctx;
end;

function ASAP_Do6502Frame(ctx: TASAP): Integer;
var
  conditionValue1: Integer;
  cycles: Integer;
  conditionValue2: Integer;
  i: Integer;
begin
  ctx.nextEventCycle := S32(0);
  ctx.nextScanlineCycle := S32(0);
  if (ctx.nmist = NmiStatus_RESET) then
  begin
    conditionValue1 := NmiStatus_ON_V_BLANK;
  end
  else
  begin
    conditionValue1 := NmiStatus_WAS_V_BLANK;
  end;
  ctx.nmist := S32(conditionValue1);
  if ASAPInfo_IsNtsc(ctx.moduleInfo) then
  begin
    conditionValue2 := 29868;
  end
  else
  begin
    conditionValue2 := 35568;
  end;
  cycles := S32(conditionValue2);
  Cpu6502_DoFrame(ctx.cpu, cycles);
  ctx.cpu.cycle := S32(Int64(ctx.cpu.cycle) - cycles);
  if (ctx.nextPlayerCycle <> 8388608) then
  begin
    ctx.nextPlayerCycle := S32(Int64(ctx.nextPlayerCycle) - cycles);
  end;
  i := S32(3);
  while True do
  begin
    PokeyChannel_EndFrame(ctx.pokeys.basePokey.channels[i], cycles);
    PokeyChannel_EndFrame(ctx.pokeys.extraPokey.channels[i], cycles);
    if (i = 0) then
    begin
      Break;
    end;
    i := S32(Sar32(i, 1));
  end;
  Exit(S32(cycles));
end;

function ASAP_Do6502Init(ctx: TASAP; pc: Integer; a: Integer; x: Integer; y: Integer): Boolean;
var
  frame: Integer;
begin
  ctx.cpu.pc := S32(pc);
  ctx.cpu.a := S32((a and 255));
  ctx.cpu.x := S32((x and 255));
  ctx.cpu.y := S32((y and 255));
  ctx.cpu.memory[53760] := U8(210);
  ctx.cpu.memory[510] := U8(255);
  ctx.cpu.memory[511] := U8(209);
  ctx.cpu.s := S32(253);
  frame := S32(0);
  while (frame < 50) do
  begin
    ASAP_Do6502Frame(ctx);
    if (ctx.cpu.pc = 53760) then
    begin
      Exit(True);
    end;
    frame := S32(frame + 1);
  end;
  Exit(False);
end;

function ASAP_DoFrame(ctx: TASAP): Integer;
var
  cycles: Integer;
begin
  ctx.gtiaOrCovoxPlayedThisFrame := False;
  PokeyPair_StartFrame(ctx.pokeys);
  cycles := S32(ASAP_Do6502Frame(ctx));
  PokeyPair_EndFrame(ctx.pokeys, cycles);
  Exit(S32(cycles));
end;

function ASAP_Generate(ctx: TASAP; buffer: TBytes; bufferLen: Integer; format: TASAPSampleFormat): Integer;
begin
  Exit(S32(ASAP_GenerateAt(ctx, buffer, 0, bufferLen, format)));
end;

function ASAP_GenerateAt(ctx: TASAP; buffer: TBytes; bufferOffset: Integer; bufferLen: Integer; format: TASAPSampleFormat): Integer;
var
  blockShift: Integer;
  conditionValue1: Integer;
  bufferBlocks: Integer;
  totalBlocks: Integer;
  block: Integer;
  blocks: Integer;
  cycles: Integer;
begin
  if ((ctx.silenceCycles > 0) and (ctx.silenceCyclesCounter <= 0)) then
  begin
    Exit(S32(0));
  end;
  if (format = ASAPSampleFormat_U8) then
  begin
    conditionValue1 := 1;
  end
  else
  begin
    conditionValue1 := 0;
  end;
  blockShift := S32(Int64(ASAPInfo_GetChannels(ctx.moduleInfo)) - conditionValue1);
  bufferBlocks := S32(Sar32(bufferLen, blockShift));
  if (ctx.currentDuration > 0) then
  begin
    totalBlocks := S32(ASAP_MillisecondsToBlocks(ctx, ctx.currentDuration));
    if (bufferBlocks > S32(Int64(totalBlocks) - ctx.blocksPlayed)) then
    begin
      bufferBlocks := S32(Int64(totalBlocks) - ctx.blocksPlayed);
    end;
  end;
  block := S32(0);
  while True do
  begin
    blocks := S32(PokeyPair_Generate(ctx.pokeys, buffer, S32(Int64(bufferOffset) + S32((Int64(block) shl (blockShift and 31)))), S32(Int64(bufferBlocks) - block), format));
    ctx.blocksPlayed := S32(Int64(ctx.blocksPlayed) + blocks);
    block := S32(Int64(block) + blocks);
    if (block >= bufferBlocks) then
    begin
      Break;
    end;
    cycles := S32(ASAP_DoFrame(ctx));
    if (ctx.silenceCycles > 0) then
    begin
      if (PokeyPair_IsSilent(ctx.pokeys) and not (ctx.gtiaOrCovoxPlayedThisFrame)) then
      begin
        ctx.silenceCyclesCounter := S32(Int64(ctx.silenceCyclesCounter) - cycles);
        if (ctx.silenceCyclesCounter <= 0) then
        begin
          Break;
        end;
      end
      else
      begin
        ctx.silenceCyclesCounter := S32(ctx.silenceCycles);
      end;
    end;
  end;
  Exit(S32((Int64(block) shl (blockShift and 31))));
end;

procedure ASAP_HandleEvent(ctx: TASAP);
var
  cycle: Integer;
  nextEventCycle: Integer;
begin
  cycle := S32(ctx.cpu.cycle);
  if (cycle >= ctx.nextScanlineCycle) then
  begin
    if (S32(Int64(cycle) - ctx.nextScanlineCycle) < 50) then
    begin
      cycle := S32(Int64(cycle) + 9);
      ctx.cpu.cycle := S32(cycle);
    end;
    ctx.nextScanlineCycle := S32(Int64(ctx.nextScanlineCycle) + 114);
    if (cycle >= ctx.nextPlayerCycle) then
    begin
      ASAP_Call6502Player(ctx);
      ctx.nextPlayerCycle := S32(Int64(ctx.nextPlayerCycle) + S32(Int64(114) * ASAPInfo_GetPlayerRateScanlines(ctx.moduleInfo)));
    end;
  end;
  nextEventCycle := S32(ctx.nextScanlineCycle);
  nextEventCycle := S32(Pokey_CheckIrq(ctx.pokeys.basePokey, cycle, nextEventCycle));
  nextEventCycle := S32(Pokey_CheckIrq(ctx.pokeys.extraPokey, cycle, nextEventCycle));
  ctx.nextEventCycle := S32(nextEventCycle);
end;

function ASAP_IsIrq(ctx: TASAP): Boolean;
begin
  Exit((ctx.pokeys.basePokey.irqst <> 255));
end;

function ASAP_MillisecondsToBlocks(ctx: TASAP; milliseconds: Integer): Integer;
var
  ms: Int64;
begin
  ms := milliseconds;
  Exit(S32(((ms * ctx.currentSampleRate) div 1000)));
end;

procedure ASAP_MutePokeyChannels(ctx: TASAP; mask: Integer);
begin
  Pokey_Mute(ctx.pokeys.basePokey, mask);
  Pokey_Mute(ctx.pokeys.extraPokey, Sar32(mask, 4));
end;

function ASAP_PeekHardware(ctx: TASAP; addr: Integer): Integer;
var
  conditionValue2: Integer;
  cycle: Integer;
  conditionValue3: Integer;
  conditionValue5: Integer;
begin
  case (addr and 65311) of
    53268:
      begin
        if ASAPInfo_IsNtsc(ctx.moduleInfo) then
        begin
          conditionValue2 := 15;
        end
        else
        begin
          conditionValue2 := 1;
        end;
        Exit(S32(conditionValue2));
      end;
    53279:
      begin
        Exit(S32(((not ctx.consol) and 15)));
      end;
    53770, 53786, 53774, 53790:
      begin
        Exit(S32(PokeyPair_Peek(ctx.pokeys, addr, ctx.cpu.cycle)));
      end;
    53772, 53788, 53775, 53791:
      begin
        Exit(S32(255));
      end;
    54283, 54299:
      begin
        cycle := S32(ctx.cpu.cycle);
        if ASAPInfo_IsNtsc(ctx.moduleInfo) then
        begin
          conditionValue3 := 29868;
        end
        else
        begin
          conditionValue3 := 35568;
        end;
        if (cycle > conditionValue3) then
        begin
          Exit(S32(0));
        end;
        Exit(S32((cycle div 228)));
      end;
    54287, 54303:
      begin
        case ctx.nmist of
          NmiStatus_RESET:
            begin
              Exit(S32(31));
            end;
          NmiStatus_WAS_V_BLANK:
            begin
              Exit(S32(95));
            end;
        else
          begin
            if (ctx.cpu.cycle < 28291) then
            begin
              conditionValue5 := 31;
            end
            else
            begin
              conditionValue5 := 95;
            end;
            Exit(S32(conditionValue5));
          end;
        end;
      end;
  else
    begin
      Exit(S32(ctx.cpu.memory[addr]));
    end;
  end;
end;

function ASAP_PlaySong(ctx: TASAP; song: Integer; duration: Integer): Boolean;
var
  player: Integer;
  music: Integer;
begin
  if ((song < 0) or (song >= ASAPInfo_GetSongs(ctx.moduleInfo))) then
  begin
    Exit(False);
  end;
  ctx.currentSong := S32(song);
  ctx.currentDuration := S32(duration);
  ctx.nextPlayerCycle := S32(8388608);
  ctx.blocksPlayed := S32(0);
  ctx.silenceCyclesCounter := S32(ctx.silenceCycles);
  Cpu6502_Reset(ctx.cpu);
  ctx.nmist := S32(NmiStatus_ON_V_BLANK);
  ctx.consol := S32(8);
  ctx.covox[0] := U8(128);
  ctx.covox[1] := U8(128);
  ctx.covox[2] := U8(128);
  ctx.covox[3] := U8(128);
  PokeyPair_Initialize(ctx.pokeys, ASAPInfo_IsNtsc(ctx.moduleInfo), (ASAPInfo_GetChannels(ctx.moduleInfo) > 1), ctx.currentSampleRate);
  ASAP_MutePokeyChannels(ctx, 255);
  player := S32(ctx.moduleInfo.player);
  music := S32(ASAPInfo_GetMusicAddress(ctx.moduleInfo));
  case ctx.moduleInfo.kind of
    ASAPModuleType_SAP_B:
      begin
        if not (ASAP_Do6502Init(ctx, ASAPInfo_GetInitAddress(ctx.moduleInfo), song, 0, 0)) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_SAP_C, ASAPModuleType_CMC, ASAPModuleType_CM3, ASAPModuleType_CMR, ASAPModuleType_CMS:
      begin
        if not (ASAP_Do6502Init(ctx, S32(Int64(player) + 3), 112, music, Sar32(music, 8))) then
        begin
          Exit(False);
        end;
        if not (ASAP_Do6502Init(ctx, S32(Int64(player) + 3), 0, song, 0)) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_SAP_D, ASAPModuleType_SAP_S:
      begin
        ctx.cpu.pc := S32(ASAPInfo_GetInitAddress(ctx.moduleInfo));
        ctx.cpu.a := S32(song);
        ctx.cpu.x := S32(0);
        ctx.cpu.y := S32(0);
        ctx.cpu.s := S32(255);
      end;
    ASAPModuleType_DLT:
      begin
        if not (ASAP_Do6502Init(ctx, S32(Int64(player) + 256), 0, 0, ctx.moduleInfo.songPos[song])) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_MPT, ASAPModuleType_MD1:
      begin
        if not (ASAP_Do6502Init(ctx, player, 0, Sar32(music, 8), music)) then
        begin
          Exit(False);
        end;
        if ctx.moduleInfo.kind = ASAPModuleType_MD1 then
          if not ASAP_Do6502Init(ctx, player, 3, ctx.mptSamplesPage - 1, 224) then
            Exit(False);
        if not (ASAP_Do6502Init(ctx, player, 2, ctx.moduleInfo.songPos[song], 0)) then
        begin
          Exit(False);
        end;
        if ctx.moduleInfo.kind = ASAPModuleType_MD1 then
        begin
          ctx.cpu.pc := player;
          ctx.cpu.a := 5;
          ctx.cpu.x := Ord(ctx.mptSamples15kHz);
          ctx.cpu.s := 255;
        end;
      end;
    ASAPModuleType_D15:
      begin
        ctx.mptSamplesCurrentAddress := Integer(ctx.cpu.memory[music + song]) * 256;
        ctx.mptSamplesSecondNibble := False;
        ctx.cpu.memory[$D200] := $D2;
        ctx.cpu.pc := $D200;
      end;
    ASAPModuleType_RMT:
      begin
        if not (ASAP_Do6502Init(ctx, player, ctx.moduleInfo.songPos[song], music, Sar32(music, 8))) then
        begin
          Exit(False);
        end;
      end;
    ASAPModuleType_TMC, ASAPModuleType_TM2:
      begin
        if not (ASAP_Do6502Init(ctx, player, 112, Sar32(music, 8), music)) then
        begin
          Exit(False);
        end;
        if not (ASAP_Do6502Init(ctx, player, 0, song, 0)) then
        begin
          Exit(False);
        end;
        ctx.tmcPerFrameCounter := S32(1);
      end;
    ASAPModuleType_FC:
      begin
        if not (ASAP_Do6502Init(ctx, player, song, 0, 0)) then
        begin
          Exit(False);
        end;
      end;
  end;
  ASAP_MutePokeyChannels(ctx, 0);
  ctx.nextPlayerCycle := S32(0);
  Exit(True);
end;

procedure ASAP_PokeHardware(ctx: TASAP; addr: Integer; data: Integer);
var
  t: Integer;
  x: Integer;
  conditionValue1: Integer;
  conditionValue2: Integer;
  pokey: TPokey;
  delta: Integer;
  cycle: Integer;
begin
  if (Sar32(addr, 8) = 210) then
  begin
    t := S32(PokeyPair_Poke(ctx.pokeys, addr, data, ctx.cpu.cycle));
    if (ctx.nextEventCycle > t) then
    begin
      ctx.nextEventCycle := S32(t);
    end;
  end
  else
  begin
    if ((addr and 65295) = 54282) then
    begin
      x := S32((ctx.cpu.cycle mod 114));
      if (x <= 106) then
      begin
        conditionValue1 := 106;
      end
      else
      begin
        conditionValue1 := 220;
      end;
      ctx.cpu.cycle := S32(Int64(ctx.cpu.cycle) + S32(Int64(conditionValue1) - x));
    end
    else
    begin
      if ((addr and 65295) = 54287) then
      begin
        if (ctx.cpu.cycle < 28292) then
        begin
          conditionValue2 := NmiStatus_ON_V_BLANK;
        end
        else
        begin
          conditionValue2 := NmiStatus_RESET;
        end;
        ctx.nmist := S32(conditionValue2);
      end
      else
      begin
        if ((addr and 65280) = ASAPInfo_GetCovoxAddress(ctx.moduleInfo)) then
        begin
          addr := S32(Int64(addr) and 3);
          if ((addr = 0) or (addr = 3)) then
          begin
            pokey := ctx.pokeys.basePokey;
          end
          else
          begin
            pokey := ctx.pokeys.extraPokey;
          end;
          delta := S32(Int64(data) - ctx.covox[addr]);
          if (delta <> 0) then
          begin
            Pokey_AddExternalDelta(pokey, ctx.pokeys, ctx.cpu.cycle, S32((Int64(delta) shl (17 and 31))));
            ctx.covox[addr] := U8(data);
            ctx.gtiaOrCovoxPlayedThisFrame := True;
          end;
        end
        else
        begin
          if ((addr and 65311) = 53279) then
          begin
            delta := S32((Int64(S32(Int64((ctx.consol and 8)) - (data and 8))) shl (20 and 31)));
            if (delta <> 0) then
            begin
              cycle := S32(ctx.cpu.cycle);
              Pokey_AddExternalDelta(ctx.pokeys.basePokey, ctx.pokeys, cycle, delta);
              Pokey_AddExternalDelta(ctx.pokeys.extraPokey, ctx.pokeys, cycle, delta);
              ctx.gtiaOrCovoxPlayedThisFrame := True;
            end;
            ctx.consol := S32(data);
          end
          else
          begin
            ctx.cpu.memory[addr] := U8(data);
          end;
        end;
      end;
    end;
  end;
end;

procedure Cpu6502_AddWithCarry(ctx: TCpu6502; data: Integer);
var
  a: Integer;
  vdi: Integer;
  tmp: Integer;
  al: Integer;
  conditionValue1: Integer;
begin
  a := S32(ctx.a);
  vdi := S32(ctx.vdi);
  tmp := S32(Int64(S32(Int64(a) + data)) + ctx.c);
  ctx.nz := S32((tmp and 255));
  if ((vdi and 8) = 0) then
  begin
    ctx.vdi := S32(Int64((vdi and 12)) + (Sar32(((not (data xor a)) and (a xor tmp)), 1) and 64));
    ctx.c := S32(Sar32(tmp, 8));
    ctx.a := S32(ctx.nz);
  end
  else
  begin
    al := S32(Int64(S32(Int64((a and 15)) + (data and 15))) + ctx.c);
    if (al >= 10) then
    begin
      if (al < 26) then
      begin
        conditionValue1 := 6;
      end
      else
      begin
        conditionValue1 := (-10);
      end;
      tmp := S32(Int64(tmp) + conditionValue1);
      if (ctx.nz <> 0) then
      begin
        ctx.nz := S32(Int64((tmp and 128)) + 1);
      end;
    end;
    ctx.vdi := S32(Int64((vdi and 12)) + (Sar32(((not (data xor a)) and (a xor tmp)), 1) and 64));
    if (tmp >= 160) then
    begin
      ctx.c := S32(1);
      ctx.a := S32((S32(Int64(tmp) - 160) and 255));
    end
    else
    begin
      ctx.c := S32(0);
      ctx.a := S32(tmp);
    end;
  end;
end;

function Cpu6502_ArithmeticShiftLeft(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Cpu6502_PeekReadModifyWrite(ctx, addr));
  ctx.c := S32(Sar32(data, 7));
  data := S32((S32((Int64(data) shl (1 and 31))) and 255));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

procedure Cpu6502_CheckIrq(ctx: TCpu6502);
begin
  if (((ctx.vdi and 4) = 0) and ASAP_IsIrq(ctx.asap)) then
  begin
    ctx.cycle := S32(Int64(ctx.cycle) + 7);
    Cpu6502_ExecuteIrq(ctx, 32);
  end;
end;

function Cpu6502_Decrement(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32((S32(Int64(Cpu6502_PeekReadModifyWrite(ctx, addr)) - 1) and 255));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

// Resolves addressing modes and executes instructions without a memory operand.
// True requests the second stage, including a taken relative branch.
function Cpu6502_DecodeOperand(ctx: TCpu6502; opcode: Integer; out addr: Integer): Boolean;
var
  data: Integer;
  operandPC5: Integer;
  operandPC8: Integer;
  operandPC9: Integer;
  operandPC10: Integer;
  operandPC11: Integer;
  operandPC12: Integer;
  zp: Integer;
  operandPC14: Integer;
  operandPC16: Integer;
  operandPC17: Integer;
  operandPC18: Integer;
  operandPC20: Integer;
  operandPC21: Integer;
  operandPC22: Integer;
  operandPC24: Integer;
  operandPC26: Integer;
  operandPC27: Integer;
  operandPC28: Integer;
  operandPC29: Integer;
  operandPC31: Integer;
  operandPC32: Integer;
  operandPC34: Integer;
  operandPC36: Integer;
  operandPC38: Integer;
  hi: Integer;
  operandPC39: Integer;
  operandPC40: Integer;
  operandPC42: Integer;
  conditionValue43: Integer;
begin
  addr := 0;
  case opcode of
    0:
      begin
        ctx.pc := S32(ctx.pc + 1);
        Cpu6502_ExecuteIrq(ctx, 48);
        Exit(False);
      end;
    1, 3, 33, 35, 65, 67, 97, 99, 129, 131, 161, 163, 193, 195, 225, 227:
      begin
        operandPC5 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(ctx.memory[operandPC5]) + ctx.x) and 255));
        addr := S32(Int64(ctx.memory[addr]) + S32((Int64(ctx.memory[(S32(Int64(addr) + 1) and 255)]) shl (8 and 31))));
        Exit(True);
      end;
    2, 18, 34, 50, 66, 82, 98, 114, 146, 178, 210, 242:
      begin
        ctx.pc := S32(ctx.pc - 1);
        ctx.cycle := S32(ctx.asap.nextEventCycle);
        Exit(False);
      end;
    4, 68, 100, 20, 52, 84, 116, 212, 244, 128, 130, 137, 194, 226:
      begin
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    5, 6, 7, 36, 37, 38, 39, 69, 70, 71, 101, 102, 103, 132, 133, 134, 135, 164, 165, 166, 167, 196, 197, 198, 199, 228, 229, 230, 231:
      begin
        operandPC8 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC8]);
        Exit(True);
      end;
    8:
      begin
        Cpu6502_PushFlags(ctx, 48);
        Exit(False);
      end;
    9, 41, 73, 105, 160, 162, 169, 192, 201, 224, 233, 235:
      begin
        operandPC9 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(operandPC9);
        Exit(True);
      end;
    10:
      begin
        ctx.c := S32(Sar32(ctx.a, 7));
        ctx.a := S32((S32((Int64(ctx.a) shl (1 and 31))) and 255));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    11, 43:
      begin
        operandPC10 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.a := S32(Int64(ctx.a) and ctx.memory[operandPC10]);
        ctx.nz := S32(ctx.a);
        ctx.c := S32(Sar32(ctx.nz, 7));
        Exit(False);
      end;
    12:
      begin
        ctx.pc := S32(Int64(ctx.pc) + 2);
        Exit(False);
      end;
    13, 14, 15, 44, 45, 46, 47, 77, 78, 79, 108, 109, 110, 111, 140, 141, 142, 143, 172, 173, 174, 175, 204, 205, 206, 207, 236, 237, 238, 239:
      begin
        operandPC11 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC11]);
        operandPC12 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(addr) + S32((Int64(ctx.memory[operandPC12]) shl (8 and 31))));
        Exit(True);
      end;
    16:
      begin
        if (ctx.nz < 128) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    17, 49, 81, 113, 177, 179, 209, 241:
      begin
        operandPC14 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        zp := S32(ctx.memory[operandPC14]);
        addr := S32(Int64(ctx.memory[zp]) + ctx.y);
        if (addr >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[(S32(Int64(zp) + 1) and 255)]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    19, 51, 83, 115, 145, 211, 243:
      begin
        operandPC16 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC16]);
        addr := S32((S32(Int64(S32(Int64(ctx.memory[addr]) + S32((Int64(ctx.memory[(S32(Int64(addr) + 1) and 255)]) shl (8 and 31))))) + ctx.y) and 65535));
        Exit(True);
      end;
    21, 22, 23, 53, 54, 55, 85, 86, 87, 117, 118, 119, 148, 149, 180, 181, 213, 214, 215, 245, 246, 247:
      begin
        operandPC17 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(ctx.memory[operandPC17]) + ctx.x) and 255));
        Exit(True);
      end;
    24:
      begin
        ctx.c := S32(0);
        Exit(False);
      end;
    25, 57, 89, 121, 185, 187, 190, 191, 217, 249:
      begin
        operandPC18 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC18]) + ctx.y);
        if (addr >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        operandPC20 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC20]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    27, 59, 91, 123, 153, 219, 251:
      begin
        operandPC21 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC21]) + ctx.y);
        operandPC22 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC22]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    28, 60, 92, 124, 220, 252:
      begin
        if (S32(Int64(ctx.memory[ctx.pc]) + ctx.x) >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        ctx.pc := S32(Int64(ctx.pc) + 2);
        Exit(False);
      end;
    29, 61, 93, 125, 188, 189, 221, 253:
      begin
        operandPC24 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC24]) + ctx.x);
        if (addr >= 256) then
        begin
          ctx.cycle := S32(ctx.cycle + 1);
        end;
        operandPC26 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC26]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    30, 31, 62, 63, 94, 95, 126, 127, 157, 222, 223, 254, 255:
      begin
        operandPC27 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(ctx.memory[operandPC27]) + ctx.x);
        operandPC28 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(addr) + S32((Int64(ctx.memory[operandPC28]) shl (8 and 31)))) and 65535));
        Exit(True);
      end;
    32:
      begin
        operandPC29 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC29]);
        Cpu6502_PushPc(ctx);
        ctx.pc := S32(Int64(addr) + S32((Int64(ctx.memory[ctx.pc]) shl (8 and 31))));
        Exit(False);
      end;
    40:
      begin
        Cpu6502_PullFlags(ctx);
        Cpu6502_CheckIrq(ctx);
        Exit(False);
      end;
    42:
      begin
        ctx.a := S32(Int64(S32((Int64(ctx.a) shl (1 and 31)))) + ctx.c);
        ctx.c := S32(Sar32(ctx.a, 8));
        ctx.a := S32(Int64(ctx.a) and 255);
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    48:
      begin
        if (ctx.nz >= 128) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    56:
      begin
        ctx.c := S32(1);
        Exit(False);
      end;
    64:
      begin
        Cpu6502_PullFlags(ctx);
        ctx.pc := S32(Cpu6502_Pull(ctx));
        ctx.pc := S32(Int64(ctx.pc) + S32((Int64(Cpu6502_Pull(ctx)) shl (8 and 31))));
        Cpu6502_CheckIrq(ctx);
        Exit(False);
      end;
    72:
      begin
        Cpu6502_Push(ctx, ctx.a);
        Exit(False);
      end;
    74:
      begin
        ctx.c := S32((ctx.a and 1));
        ctx.a := S32(Sar32(ctx.a, 1));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    75:
      begin
        operandPC31 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.a := S32(Int64(ctx.a) and ctx.memory[operandPC31]);
        ctx.c := S32((ctx.a and 1));
        ctx.a := S32(Sar32(ctx.a, 1));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    76:
      begin
        operandPC32 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC32]);
        ctx.pc := S32(Int64(addr) + S32((Int64(ctx.memory[ctx.pc]) shl (8 and 31))));
        Exit(False);
      end;
    80:
      begin
        if ((ctx.vdi and 64) = 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    88:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) and 72);
        Cpu6502_CheckIrq(ctx);
        Exit(False);
      end;
    96:
      begin
        ctx.pc := S32(Cpu6502_Pull(ctx));
        ctx.pc := S32(Int64(ctx.pc) + S32(Int64(S32((Int64(Cpu6502_Pull(ctx)) shl (8 and 31)))) + 1));
        Exit(False);
      end;
    104:
      begin
        ctx.a := S32(Cpu6502_Pull(ctx));
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    106:
      begin
        ctx.nz := S32(Int64(S32((Int64(ctx.c) shl (7 and 31)))) + Sar32(ctx.a, 1));
        ctx.c := S32((ctx.a and 1));
        ctx.a := S32(ctx.nz);
        Exit(False);
      end;
    107:
      begin
        operandPC34 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        data := S32((ctx.a and ctx.memory[operandPC34]));
        ctx.a := S32(Int64(Sar32(data, 1)) + S32((Int64(ctx.c) shl (7 and 31))));
        ctx.nz := S32(ctx.a);
        ctx.vdi := S32(Int64((ctx.vdi and 12)) + ((ctx.a xor data) and 64));
        if ((ctx.vdi and 8) = 0) then
        begin
          ctx.c := S32(Sar32(data, 7));
        end
        else
        begin
          if ((data and 15) >= 5) then
          begin
            ctx.a := S32(Int64((ctx.a and 240)) + (S32(Int64(ctx.a) + 6) and 15));
          end;
          if (data >= 80) then
          begin
            ctx.a := S32((S32(Int64(ctx.a) + 96) and 255));
            ctx.c := S32(1);
          end
          else
          begin
            ctx.c := S32(0);
          end;
        end;
        Exit(False);
      end;
    112:
      begin
        if ((ctx.vdi and 64) <> 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    120:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) or 4);
        Exit(False);
      end;
    136:
      begin
        ctx.y := S32((S32(Int64(ctx.y) - 1) and 255));
        ctx.nz := S32(ctx.y);
        Exit(False);
      end;
    138:
      begin
        ctx.a := S32(ctx.x);
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    139:
      begin
        operandPC36 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        data := S32(ctx.memory[operandPC36]);
        ctx.a := S32(Int64(ctx.a) and ((data or 239) and ctx.x));
        ctx.nz := S32((ctx.a and data));
        Exit(False);
      end;
    144:
      begin
        if (ctx.c = 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    147:
      begin
        operandPC38 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(ctx.memory[operandPC38]);
        hi := S32(ctx.memory[(S32(Int64(addr) + 1) and 255)]);
        addr := S32(ctx.memory[addr]);
        data := S32(((S32(Int64(hi) + 1) and ctx.a) and ctx.x));
        addr := S32(Int64(addr) + ctx.y);
        if (addr >= 256) then
        begin
          hi := S32(Int64(data) - 1);
        end;
        addr := S32(Int64(addr) + S32((Int64(hi) shl (8 and 31))));
        Cpu6502_Poke(ctx, addr, data);
        Exit(False);
      end;
    150, 151, 182, 183:
      begin
        operandPC39 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        addr := S32((S32(Int64(ctx.memory[operandPC39]) + ctx.y) and 255));
        Exit(True);
      end;
    152:
      begin
        ctx.a := S32(ctx.y);
        ctx.nz := S32(ctx.a);
        Exit(False);
      end;
    154:
      begin
        ctx.s := S32(ctx.x);
        Exit(False);
      end;
    155:
      begin
        ctx.s := S32((ctx.a and ctx.x));
        Cpu6502_Shx(ctx, ctx.y, ctx.s);
        Exit(False);
      end;
    156:
      begin
        Cpu6502_Shx(ctx, ctx.x, ctx.y);
        Exit(False);
      end;
    158:
      begin
        Cpu6502_Shx(ctx, ctx.y, ctx.x);
        Exit(False);
      end;
    159:
      begin
        Cpu6502_Shx(ctx, ctx.y, (ctx.a and ctx.x));
        Exit(False);
      end;
    168:
      begin
        ctx.y := S32(ctx.a);
        ctx.nz := S32(ctx.y);
        Exit(False);
      end;
    170:
      begin
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    171:
      begin
        operandPC40 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.a := S32(Int64(ctx.a) and ctx.memory[operandPC40]);
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    176:
      begin
        if (ctx.c <> 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    184:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) and 12);
        Exit(False);
      end;
    186:
      begin
        ctx.x := S32(ctx.s);
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    200:
      begin
        ctx.y := S32((S32(Int64(ctx.y) + 1) and 255));
        ctx.nz := S32(ctx.y);
        Exit(False);
      end;
    202:
      begin
        ctx.x := S32((S32(Int64(ctx.x) - 1) and 255));
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    203:
      begin
        operandPC42 := ctx.pc;
        ctx.pc := S32(ctx.pc + 1);
        ctx.nz := S32(ctx.memory[operandPC42]);
        ctx.x := S32(Int64(ctx.x) and ctx.a);
        if (ctx.x >= ctx.nz) then
        begin
          conditionValue43 := 1;
        end
        else
        begin
          conditionValue43 := 0;
        end;
        ctx.c := S32(conditionValue43);
        ctx.x := S32((S32(Int64(ctx.x) - ctx.nz) and 255));
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    208:
      begin
        if ((ctx.nz and 255) <> 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    216:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) and 68);
        Exit(False);
      end;
    232:
      begin
        ctx.x := S32((S32(Int64(ctx.x) + 1) and 255));
        ctx.nz := S32(ctx.x);
        Exit(False);
      end;
    234, 26, 58, 90, 122, 218, 250:
      begin
        Exit(False);
      end;
    240:
      begin
        if ((ctx.nz and 255) = 0) then
        begin
          Exit(True);
        end;
        ctx.pc := S32(ctx.pc + 1);
        Exit(False);
      end;
    248:
      begin
        ctx.vdi := S32(Int64(ctx.vdi) or 8);
        Exit(False);
      end;
  else
    begin
      abort();
    end;
  end;
end;

// Applies the memory operation after its addressing mode has been resolved.
procedure Cpu6502_ExecuteOperand(ctx: TCpu6502; opcode, addr: Integer);
var
  data: Integer;
  conditionValue48: Integer;
  conditionValue49: Integer;
  conditionValue50: Integer;
  conditionValue51: Integer;
  conditionValue52: Integer;
begin
  case opcode of
    1, 5, 9, 13, 17, 21, 25, 29:
      begin
        ctx.a := S32(Int64(ctx.a) or Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    3, 7, 15, 19, 23, 27, 31:
      begin
        ctx.a := S32(Int64(ctx.a) or Cpu6502_ArithmeticShiftLeft(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    6, 14, 22, 30:
      begin
        ctx.nz := S32(Cpu6502_ArithmeticShiftLeft(ctx, addr));
      end;
    16, 48, 80, 112, 144, 176, 208, 240:
      begin
        addr := S32(Int64((ctx.memory[ctx.pc] xor 128)) - 128);
        ctx.pc := S32(ctx.pc + 1);
        addr := S32(Int64(addr) + ctx.pc);
        if (Sar32((addr xor ctx.pc), 8) <> 0) then
        begin
          conditionValue48 := 2;
        end
        else
        begin
          conditionValue48 := 1;
        end;
        ctx.cycle := S32(Int64(ctx.cycle) + conditionValue48);
        ctx.pc := S32(addr);
      end;
    33, 37, 41, 45, 49, 53, 57, 61:
      begin
        ctx.a := S32(Int64(ctx.a) and Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    35, 39, 47, 51, 55, 59, 63:
      begin
        ctx.a := S32(Int64(ctx.a) and Cpu6502_RotateLeft(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    36, 44:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        ctx.vdi := S32(Int64((ctx.vdi and 12)) + (ctx.nz and 64));
        ctx.nz := S32(Int64(S32((Int64((ctx.nz and 128)) shl (1 and 31)))) + (ctx.nz and ctx.a));
      end;
    38, 46, 54, 62:
      begin
        ctx.nz := S32(Cpu6502_RotateLeft(ctx, addr));
      end;
    65, 69, 73, 77, 81, 85, 89, 93:
      begin
        ctx.a := S32(Int64(ctx.a) xor Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    67, 71, 79, 83, 87, 91, 95:
      begin
        ctx.a := S32(Int64(ctx.a) xor Cpu6502_LogicalShiftRight(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    70, 78, 86, 94:
      begin
        ctx.nz := S32(Cpu6502_LogicalShiftRight(ctx, addr));
      end;
    97, 101, 105, 109, 113, 117, 121, 125:
      begin
        Cpu6502_AddWithCarry(ctx, Cpu6502_Peek(ctx, addr));
      end;
    99, 103, 111, 115, 119, 123, 127:
      begin
        Cpu6502_AddWithCarry(ctx, Cpu6502_RotateRight(ctx, addr));
      end;
    102, 110, 118, 126:
      begin
        ctx.nz := S32(Cpu6502_RotateRight(ctx, addr));
      end;
    108:
      begin
        ctx.pc := S32(ctx.memory[addr]);
        addr := S32(addr + 1);
        if ((addr and 255) = 0) then
        begin
          addr := S32(Int64(addr) - 255);
        end;
        ctx.pc := S32(Int64(ctx.pc) + S32((Int64(ctx.memory[addr]) shl (8 and 31))));
      end;
    129, 133, 141, 145, 149, 153, 157:
      begin
        Cpu6502_Poke(ctx, addr, ctx.a);
      end;
    131, 135, 143, 151:
      begin
        Cpu6502_Poke(ctx, addr, (ctx.a and ctx.x));
      end;
    132, 140, 148:
      begin
        Cpu6502_Poke(ctx, addr, ctx.y);
      end;
    134, 142, 150:
      begin
        Cpu6502_Poke(ctx, addr, ctx.x);
      end;
    160, 164, 172, 180, 188:
      begin
        ctx.y := S32(Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.y);
      end;
    161, 165, 169, 173, 177, 181, 185, 189:
      begin
        ctx.a := S32(Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.a);
      end;
    162, 166, 174, 182, 190:
      begin
        ctx.x := S32(Cpu6502_Peek(ctx, addr));
        ctx.nz := S32(ctx.x);
      end;
    163, 167, 175, 179, 183, 191:
      begin
        ctx.a := S32(Cpu6502_Peek(ctx, addr));
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
      end;
    187:
      begin
        ctx.s := S32(Int64(ctx.s) and Cpu6502_Peek(ctx, addr));
        ctx.a := S32(ctx.s);
        ctx.x := S32(ctx.a);
        ctx.nz := S32(ctx.x);
      end;
    192, 196, 204:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        if (ctx.y >= ctx.nz) then
        begin
          conditionValue49 := 1;
        end
        else
        begin
          conditionValue49 := 0;
        end;
        ctx.c := S32(conditionValue49);
        ctx.nz := S32((S32(Int64(ctx.y) - ctx.nz) and 255));
      end;
    193, 197, 201, 205, 209, 213, 217, 221:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        if (ctx.a >= ctx.nz) then
        begin
          conditionValue50 := 1;
        end
        else
        begin
          conditionValue50 := 0;
        end;
        ctx.c := S32(conditionValue50);
        ctx.nz := S32((S32(Int64(ctx.a) - ctx.nz) and 255));
      end;
    195, 199, 207, 211, 215, 219, 223:
      begin
        data := S32(Cpu6502_Decrement(ctx, addr));
        if (ctx.a >= data) then
        begin
          conditionValue51 := 1;
        end
        else
        begin
          conditionValue51 := 0;
        end;
        ctx.c := S32(conditionValue51);
        ctx.nz := S32((S32(Int64(ctx.a) - data) and 255));
      end;
    198, 206, 214, 222:
      begin
        ctx.nz := S32(Cpu6502_Decrement(ctx, addr));
      end;
    224, 228, 236:
      begin
        ctx.nz := S32(Cpu6502_Peek(ctx, addr));
        if (ctx.x >= ctx.nz) then
        begin
          conditionValue52 := 1;
        end
        else
        begin
          conditionValue52 := 0;
        end;
        ctx.c := S32(conditionValue52);
        ctx.nz := S32((S32(Int64(ctx.x) - ctx.nz) and 255));
      end;
    225, 229, 233, 235, 237, 241, 245, 249, 253:
      begin
        Cpu6502_SubtractWithCarry(ctx, Cpu6502_Peek(ctx, addr));
      end;
    227, 231, 239, 243, 247, 251, 255:
      begin
        Cpu6502_SubtractWithCarry(ctx, Cpu6502_Increment(ctx, addr));
      end;
    230, 238, 246, 254:
      begin
        ctx.nz := S32(Cpu6502_Increment(ctx, addr));
      end;
  else
    begin
      abort();
    end;
  end;
end;

procedure Cpu6502_DoFrame(ctx: TCpu6502; cycleLimit: Integer);
var
  opcode, address, instructionPC: Integer;
begin
  while ctx.cycle < cycleLimit do
  begin
    if ctx.cycle >= ctx.asap.nextEventCycle then
    begin
      ASAP_HandleEvent(ctx.asap);
      Cpu6502_CheckIrq(ctx);
    end;
    instructionPC := ctx.pc;
    ctx.pc := S32(Int64(ctx.pc) + 1);
    opcode := ctx.memory[instructionPC];
    ctx.cycle := S32(Int64(ctx.cycle) + OpcodeCycles[opcode]);
    if Cpu6502_DecodeOperand(ctx, opcode, address) then
      Cpu6502_ExecuteOperand(ctx, opcode, address);
  end;
end;

procedure Cpu6502_ExecuteIrq(ctx: TCpu6502; b: Integer);
begin
  Cpu6502_PushPc(ctx);
  Cpu6502_PushFlags(ctx, b);
  ctx.vdi := S32(Int64(ctx.vdi) or 4);
  ctx.pc := S32(Int64(ctx.memory[65534]) + S32((Int64(ctx.memory[65535]) shl (8 and 31))));
end;

function Cpu6502_Increment(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32((S32(Int64(Cpu6502_PeekReadModifyWrite(ctx, addr)) + 1) and 255));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

function Cpu6502_LogicalShiftRight(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Cpu6502_PeekReadModifyWrite(ctx, addr));
  ctx.c := S32((data and 1));
  data := S32(Sar32(data, 1));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

function Cpu6502_Peek(ctx: TCpu6502; addr: Integer): Integer;
begin
  if ((addr and 63744) = 53248) then
  begin
    Exit(S32(ASAP_PeekHardware(ctx.asap, addr)));
  end
  else
  begin
    Exit(S32(ctx.memory[addr]));
  end;
end;

function Cpu6502_PeekReadModifyWrite(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  if (Sar32(addr, 8) = 210) then
  begin
    ctx.cycle := S32(ctx.cycle - 1);
    data := S32(ASAP_PeekHardware(ctx.asap, addr));
    ASAP_PokeHardware(ctx.asap, addr, data);
    ctx.cycle := S32(ctx.cycle + 1);
    Exit(S32(data));
  end;
  Exit(S32(ctx.memory[addr]));
end;

procedure Cpu6502_Poke(ctx: TCpu6502; addr: Integer; data: Integer);
begin
  if ((addr and 63744) = 53248) then
  begin
    ASAP_PokeHardware(ctx.asap, addr, data);
  end
  else
  begin
    ctx.memory[addr] := U8(data);
  end;
end;

function Cpu6502_Pull(ctx: TCpu6502): Integer;
var
  s: Integer;
begin
  s := S32((S32(Int64(ctx.s) + 1) and 255));
  ctx.s := S32(s);
  Exit(S32(ctx.memory[S32(Int64(256) + s)]));
end;

procedure Cpu6502_PullFlags(ctx: TCpu6502);
var
  data: Integer;
begin
  data := S32(Cpu6502_Pull(ctx));
  ctx.nz := S32(Int64(S32((Int64((data and 128)) shl (1 and 31)))) + ((not data) and 2));
  ctx.c := S32((data and 1));
  ctx.vdi := S32((data and 76));
end;

procedure Cpu6502_Push(ctx: TCpu6502; data: Integer);
var
  s: Integer;
begin
  s := S32(ctx.s);
  ctx.memory[S32(Int64(256) + s)] := U8(data);
  ctx.s := S32((S32(Int64(s) - 1) and 255));
end;

procedure Cpu6502_PushFlags(ctx: TCpu6502; b: Integer);
var
  nz: Integer;
begin
  nz := S32(ctx.nz);
  b := S32(Int64(b) + S32(Int64(S32(Int64(((nz or Sar32(nz, 1)) and 128)) + ctx.vdi)) + ctx.c));
  if ((nz and 255) = 0) then
  begin
    b := S32(Int64(b) + 2);
  end;
  Cpu6502_Push(ctx, b);
end;

procedure Cpu6502_PushPc(ctx: TCpu6502);
begin
  Cpu6502_Push(ctx, Sar32(ctx.pc, 8));
  Cpu6502_Push(ctx, (ctx.pc and 255));
end;

procedure Cpu6502_Reset(ctx: TCpu6502);
begin
  ctx.cycle := S32(0);
  ctx.nz := S32(0);
  ctx.c := S32(0);
  ctx.vdi := S32(0);
end;

function Cpu6502_RotateLeft(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Int64(S32((Int64(Cpu6502_PeekReadModifyWrite(ctx, addr)) shl (1 and 31)))) + ctx.c);
  ctx.c := S32(Sar32(data, 8));
  data := S32(Int64(data) and 255);
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

function Cpu6502_RotateRight(ctx: TCpu6502; addr: Integer): Integer;
var
  data: Integer;
begin
  data := S32(Int64(S32((Int64(ctx.c) shl (8 and 31)))) + Cpu6502_PeekReadModifyWrite(ctx, addr));
  ctx.c := S32((data and 1));
  data := S32(Sar32(data, 1));
  Cpu6502_Poke(ctx, addr, data);
  Exit(S32(data));
end;

procedure Cpu6502_Shx(ctx: TCpu6502; addr: Integer; data: Integer);
var
  operandPC1: Integer;
  hi: Integer;
  operandPC2: Integer;
begin
  operandPC1 := ctx.pc;
  ctx.pc := S32(ctx.pc + 1);
  addr := S32(Int64(addr) + ctx.memory[operandPC1]);
  operandPC2 := ctx.pc;
  ctx.pc := S32(ctx.pc + 1);
  hi := S32(ctx.memory[operandPC2]);
  data := S32(Int64(data) and S32(Int64(hi) + 1));
  if (addr >= 256) then
  begin
    hi := S32(Int64(data) - 1);
  end;
  addr := S32(Int64(addr) + S32((Int64(hi) shl (8 and 31))));
  Cpu6502_Poke(ctx, addr, data);
end;

procedure Cpu6502_SubtractWithCarry(ctx: TCpu6502; data: Integer);
var
  a: Integer;
  vdi: Integer;
  borrow: Integer;
  tmp: Integer;
  al: Integer;
  conditionValue1: Integer;
  conditionValue2: Integer;
begin
  a := S32(ctx.a);
  vdi := S32(ctx.vdi);
  borrow := S32(Int64(ctx.c) - 1);
  tmp := S32(Int64(S32(Int64(a) - data)) + borrow);
  al := S32(Int64(S32(Int64((a and 15)) - (data and 15))) + borrow);
  ctx.vdi := S32(Int64((vdi and 12)) + (Sar32(((data xor a) and (a xor tmp)), 1) and 64));
  if (tmp >= 0) then
  begin
    conditionValue1 := 1;
  end
  else
  begin
    conditionValue1 := 0;
  end;
  ctx.c := S32(conditionValue1);
  ctx.a := S32((tmp and 255));
  ctx.nz := S32(ctx.a);
  if ((vdi and 8) <> 0) then
  begin
    if (al < 0) then
    begin
      if (al < (-10)) then
      begin
        conditionValue2 := 10;
      end
      else
      begin
        conditionValue2 := (-6);
      end;
      ctx.a := S32(Int64(ctx.a) + conditionValue2);
    end;
    if (ctx.c = 0) then
    begin
      ctx.a := S32((S32(Int64(ctx.a) - 96) and 255));
    end;
  end;
end;

procedure PokeyChannel_DoStimer(ctx: TPokeyChannel; cycle: Integer);
begin
  if (ctx.tickCycle <> 8388608) then
  begin
    ctx.tickCycle := S32(Int64(cycle) + ctx.periodCycles);
  end;
end;

procedure PokeyChannel_DoTick(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer; ch: Integer);
var
  audc: Integer;
  poly: Integer;
  newOut: Integer;
begin
  ctx.tickCycle := S32(Int64(ctx.tickCycle) + ctx.periodCycles);
  audc := S32(ctx.audc);
  if ((audc and 176) = 160) then
  begin
    ctx.output := S32(Int64(ctx.output) xor 1);
  end
  else
  begin
    if (((audc and 16) <> 0) or pokey.init) then
    begin
      Exit;
    end
    else
    begin
      poly := S32(Int64(S32(Int64(cycle) + pokey.polyIndex)) - ch);
      if ((audc < 128) and ((1706902752 and S32((Int64(1) shl ((poly mod 31) and 31)))) = 0)) then
      begin
        Exit;
      end;
      if ((audc and 32) <> 0) then
      begin
        ctx.output := S32(Int64(ctx.output) xor 1);
      end
      else
      begin
        if ((audc and 64) <> 0) then
        begin
          newOut := S32(Sar32(21360, (poly mod 15)));
        end
        else
        begin
          if (pokey.audctl < 128) then
          begin
            poly := S32(Int64(poly) mod 131071);
            newOut := S32(Sar32(pokeys.poly17Lookup[Sar32(poly, 3)], (poly and 7)));
          end
          else
          begin
            newOut := S32(pokeys.poly9Lookup[(poly mod 511)]);
          end;
        end;
        newOut := S32(Int64(newOut) and 1);
        if (ctx.output = newOut) then
        begin
          Exit;
        end;
        ctx.output := S32(newOut);
      end;
    end;
  end;
  PokeyChannel_Slope(ctx, pokey, pokeys, cycle);
end;

procedure PokeyChannel_EndFrame(ctx: TPokeyChannel; cycle: Integer);
begin
  if (ctx.timerCycle <> 8388608) then
  begin
    ctx.timerCycle := S32(Int64(ctx.timerCycle) - cycle);
  end;
end;

procedure PokeyChannel_Initialize(ctx: TPokeyChannel);
begin
  ctx.audf := S32(0);
  ctx.audc := S32(0);
  ctx.periodCycles := S32(28);
  ctx.tickCycle := S32(8388608);
  ctx.timerCycle := S32(8388608);
  ctx.mute := S32(0);
  ctx.output := S32(0);
  ctx.delta := S32(0);
end;

procedure PokeyChannel_SetAudc(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; data: Integer; cycle: Integer);
var
  conditionValue1: Integer;
begin
  if (ctx.audc = data) then
  begin
    Exit;
  end;
  Pokey_GenerateUntilCycle(pokey, pokeys, cycle);
  ctx.audc := S32(data);
  if ((data and 16) <> 0) then
  begin
    data := S32(Int64(data) and 15);
    if ((ctx.mute and 2) = 0) then
    begin
      if (ctx.delta > 0) then
      begin
        conditionValue1 := S32(Int64(data) - ctx.delta);
      end
      else
      begin
        conditionValue1 := data;
      end;
      Pokey_AddDelta(pokey, pokeys, cycle, conditionValue1);
    end;
    ctx.delta := S32(data);
  end
  else
  begin
    data := S32(Int64(data) and 15);
    if (ctx.delta > 0) then
    begin
      if ((ctx.mute and 2) = 0) then
      begin
        Pokey_AddDelta(pokey, pokeys, cycle, S32(Int64(data) - ctx.delta));
      end;
      ctx.delta := S32(data);
    end
    else
    begin
      ctx.delta := S32((-data));
    end;
  end;
end;

procedure PokeyChannel_SetMute(ctx: TPokeyChannel; enable: Boolean; mask: Integer; cycle: Integer);
begin
  if enable then
  begin
    ctx.mute := S32(Int64(ctx.mute) or mask);
    ctx.tickCycle := S32(8388608);
  end
  else
  begin
    ctx.mute := S32(Int64(ctx.mute) and (not mask));
    if ((ctx.mute = 0) and (ctx.tickCycle = 8388608)) then
    begin
      ctx.tickCycle := S32(cycle);
    end;
  end;
end;

procedure PokeyChannel_Slope(ctx: TPokeyChannel; pokey: TPokey; pokeys: TPokeyPair; cycle: Integer);
begin
  ctx.delta := S32((-ctx.delta));
  Pokey_AddDelta(pokey, pokeys, cycle, ctx.delta);
end;

procedure PokeyPair_Construct(ctx: TPokeyPair);
var
  reg: Integer;
  i: Integer;
  sincSum: Double;
  leftSum: Double;
  norm: Double;
  sinc: TArray<Double>;
  j: Integer;
  x: Double;
  s: Double;
  conditionValue7: Double;
begin
  Pokey_Construct(ctx.basePokey);
  Pokey_Construct(ctx.extraPokey);
  reg := S32(511);
  i := S32(0);
  while (i < 511) do
  begin
    reg := S32(Int64(S32((Int64(((Sar32(reg, 5) xor reg) and 1)) shl (8 and 31)))) + Sar32(reg, 1));
    ctx.poly9Lookup[i] := U8(reg);
    i := S32(i + 1);
  end;
  reg := S32(131071);
  i := S32(0);
  while (i < 16385) do
  begin
    reg := S32(Int64(S32((Int64(((Sar32(reg, 5) xor reg) and 255)) shl (9 and 31)))) + Sar32(reg, 8));
    ctx.poly17Lookup[i] := U8(Sar32(reg, 1));
    i := S32(i + 1);
  end;
  i := S32(0);
  while (i < 1024) do
  begin
    sincSum := 0;
    leftSum := 0;
    norm := 0;
    SetLength(sinc, 31);
    j := S32((-32));
    while (j < 32) do
    begin
      if (j = (-16)) then
      begin
        leftSum := sincSum;
      end
      else
      begin
        if (j = 15) then
        begin
          norm := sincSum;
        end;
      end;
      x := ((3.141592653589793 / 1024) * S32(Int64(S32((Int64(j) shl (10 and 31)))) - i));
      if (x = 0) then
      begin
        conditionValue7 := 1;
      end
      else
      begin
        conditionValue7 := (sin(x) / x);
      end;
      s := conditionValue7;
      if ((j >= (-16)) and (j < 15)) then
      begin
        sinc[S32(Int64(16) + j)] := s;
      end;
      sincSum := sincSum + s;
      j := S32(j + 1);
    end;
    norm := (16384 / (norm + ((1 - sincSum) * 0.5)));
    ctx.sincLookup[i][0] := S16(Round(((leftSum + ((1 - sincSum) * 0.5)) * norm)));
    j := S32(1);
    while (j < 32) do
    begin
      ctx.sincLookup[i][j] := S16(Round((sinc[S32(Int64(j) - 1)] * norm)));
      j := S32(j + 1);
    end;
    i := S32(i + 1);
  end;
end;

function PokeyPair_EndFrame(ctx: TPokeyPair; cycle: Integer): Integer;
begin
  Pokey_EndFrame(ctx.basePokey, ctx, cycle);
  if (ctx.extraPokeyMask <> 0) then
  begin
    Pokey_EndFrame(ctx.extraPokey, ctx, cycle);
  end;
  ctx.sampleOffset := S32(Int64(ctx.sampleOffset) + S32(Int64(cycle) * ctx.sampleFactor));
  ctx.readySamplesStart := S32(0);
  ctx.readySamplesEnd := S32(Sar32(ctx.sampleOffset, 18));
  ctx.sampleOffset := S32(Int64(ctx.sampleOffset) and 262143);
  Exit(S32(ctx.readySamplesEnd));
end;

function PokeyPair_Generate(ctx: TPokeyPair; buffer: TBytes; bufferOffset: Integer; blocks: Integer; format: TASAPSampleFormat): Integer;
var
  i: Integer;
  samplesEnd: Integer;
begin
  i := S32(ctx.readySamplesStart);
  samplesEnd := S32(ctx.readySamplesEnd);
  if (blocks < S32(Int64(samplesEnd) - i)) then
  begin
    samplesEnd := S32(Int64(i) + blocks);
  end
  else
  begin
    blocks := S32(Int64(samplesEnd) - i);
  end;
  if (blocks > 0) then
  begin
    while (i < samplesEnd) do
    begin
      bufferOffset := S32(Pokey_StoreSample(ctx.basePokey, buffer, bufferOffset, i, format));
      if (ctx.extraPokeyMask <> 0) then
      begin
        bufferOffset := S32(Pokey_StoreSample(ctx.extraPokey, buffer, bufferOffset, i, format));
      end;
      i := S32(i + 1);
    end;
    if (i = ctx.readySamplesEnd) then
    begin
      Pokey_AccumulateTrailing(ctx.basePokey, i);
      Pokey_AccumulateTrailing(ctx.extraPokey, i);
    end;
    ctx.readySamplesStart := S32(i);
  end;
  Exit(S32(blocks));
end;

function PokeyPair_GetSampleFactor(ctx: TPokeyPair; clock: Integer): Integer;
begin
  Exit(S32((S32(Int64(S32((Int64(ctx.sampleRate) shl (13 and 31)))) + Sar32(clock, 6)) div Sar32(clock, 5))));
end;

procedure PokeyPair_Initialize(ctx: TPokeyPair; ntsc: Boolean; stereo: Boolean; sampleRate: Integer);
var
  conditionValue1: Integer;
  conditionValue2: Integer;
begin
  if stereo then
  begin
    conditionValue1 := 16;
  end
  else
  begin
    conditionValue1 := 0;
  end;
  ctx.extraPokeyMask := S32(conditionValue1);
  ctx.sampleRate := S32(sampleRate);
  Pokey_Initialize(ctx.basePokey, sampleRate);
  Pokey_Initialize(ctx.extraPokey, sampleRate);
  if ntsc then
  begin
    conditionValue2 := PokeyPair_GetSampleFactor(ctx, 1789772);
  end
  else
  begin
    conditionValue2 := PokeyPair_GetSampleFactor(ctx, 1773447);
  end;
  ctx.sampleFactor := S32(conditionValue2);
  ctx.sampleOffset := S32(0);
  ctx.readySamplesStart := S32(0);
  ctx.readySamplesEnd := S32(0);
end;

function PokeyPair_IsSilent(ctx: TPokeyPair): Boolean;
begin
  Exit((Pokey_IsSilent(ctx.basePokey) and Pokey_IsSilent(ctx.extraPokey)));
end;

function PokeyPair_Peek(ctx: TPokeyPair; addr: Integer; cycle: Integer): Integer;
var
  pokey: TPokey;
  conditionValue1: TPokey;
  i: Integer;
  j: Integer;
begin
  if ((addr and ctx.extraPokeyMask) <> 0) then
  begin
    conditionValue1 := ctx.extraPokey;
  end
  else
  begin
    conditionValue1 := ctx.basePokey;
  end;
  pokey := conditionValue1;
  case (addr and 15) of
    10:
      begin
        if pokey.init then
        begin
          Exit(S32(255));
        end;
        i := S32(Int64(cycle) + pokey.polyIndex);
        if ((pokey.audctl and 128) <> 0) then
        begin
          Exit(S32(ctx.poly9Lookup[(i mod 511)]));
        end;
        i := S32(Int64(i) mod 131071);
        j := S32(Sar32(i, 3));
        i := S32(Int64(i) and 7);
        Exit(S32((S32(Int64(Sar32(ctx.poly17Lookup[j], i)) + S32((Int64(ctx.poly17Lookup[S32(Int64(j) + 1)]) shl (S32(Int64(8) - i) and 31)))) and 255)));
      end;
    14:
      begin
        Exit(S32(pokey.irqst));
      end;
  else
    begin
      Exit(S32(255));
    end;
  end;
end;

function PokeyPair_Poke(ctx: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;
var
  pokey: TPokey;
  conditionValue1: TPokey;
begin
  if ((addr and ctx.extraPokeyMask) <> 0) then
  begin
    conditionValue1 := ctx.extraPokey;
  end
  else
  begin
    conditionValue1 := ctx.basePokey;
  end;
  pokey := conditionValue1;
  Exit(S32(Pokey_Poke(pokey, ctx, addr, data, cycle)));
end;

procedure PokeyPair_StartFrame(ctx: TPokeyPair);
begin
  Pokey_StartFrame(ctx.basePokey);
  if (ctx.extraPokeyMask <> 0) then
  begin
    Pokey_StartFrame(ctx.extraPokey);
  end;
end;

procedure Pokey_AccumulateTrailing(ctx: TPokey; i: Integer);
begin
  ctx.trailing := S32(i);
end;

procedure Pokey_AddDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);
var
  newOutput: Integer;
begin
  ctx.sumDACInputs := S32(Int64(ctx.sumDACInputs) + delta);
  newOutput := S32((Int64(Pokey_COMPRESSED_SUMS[EnsureRange(ctx.sumDACInputs, 0, 60)]) shl (16 and 31)));
  Pokey_AddExternalDelta(ctx, pokeys, cycle, S32(Int64(newOutput) - ctx.sumDACOutputs));
  ctx.sumDACOutputs := S32(newOutput);
end;

procedure Pokey_AddExternalDelta(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer; delta: Integer);
var
  i: Integer;
  fraction: Integer;
  j: Integer;
begin
  if (delta = 0) then
  begin
    Exit;
  end;
  i := S32(Int64(S32(Int64(cycle) * pokeys.sampleFactor)) + pokeys.sampleOffset);
  fraction := S32((Sar32(i, 8) and 1023));
  i := S32(Sar32(i, 18));
  delta := S32(Sar32(delta, 14));
  j := S32(0);
  while (j < 32) do
  begin
    ctx.deltaBuffer[S32(Int64(i) + j)] := S32(Int64(ctx.deltaBuffer[S32(Int64(i) + j)]) + S32(Int64(delta) * pokeys.sincLookup[fraction][j]));
    j := S32(j + 1);
  end;
end;

function Pokey_CheckIrq(ctx: TPokey; cycle: Integer; nextEventCycle: Integer): Integer;
var
  i: Integer;
  timerCycle: Integer;
begin
  i := S32(3);
  while True do
  begin
    timerCycle := S32(ctx.channels[i].timerCycle);
    if (cycle >= timerCycle) then
    begin
      ctx.irqst := S32(Int64(ctx.irqst) and (not S32(Int64(i) + 1)));
      ctx.channels[i].timerCycle := S32(8388608);
    end
    else
    begin
      if (nextEventCycle > timerCycle) then
      begin
        nextEventCycle := S32(timerCycle);
      end;
    end;
    if (i = 0) then
    begin
      Break;
    end;
    i := S32(Sar32(i, 1));
  end;
  Exit(S32(nextEventCycle));
end;

procedure Pokey_Construct(ctx: TPokey);
begin
  ctx.deltaBuffer := nil;
end;

procedure Pokey_EndFrame(ctx: TPokey; pokeys: TPokeyPair; cycle: Integer);
var
  m: Integer;
  conditionValue1: Integer;
  c: Integer;
  tickCycle: Integer;
begin
  Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
  ctx.polyIndex := S32(Int64(ctx.polyIndex) + cycle);
  if ((ctx.audctl and 128) <> 0) then
  begin
    conditionValue1 := 237615;
  end
  else
  begin
    conditionValue1 := 60948015;
  end;
  m := S32(conditionValue1);
  if (ctx.polyIndex >= S32(Int64(2) * m)) then
  begin
    ctx.polyIndex := S32(Int64(ctx.polyIndex) - m);
  end;
  c := S32(0);
  while (c < 4) do
  begin
    tickCycle := S32(ctx.channels[c].tickCycle);
    if (tickCycle <> 8388608) then
    begin
      ctx.channels[c].tickCycle := S32(Int64(tickCycle) - cycle);
    end;
    c := S32(c + 1);
  end;
end;

procedure Pokey_GenerateUntilCycle(ctx: TPokey; pokeys: TPokeyPair; cycleLimit: Integer);
var
  cycle: Integer;
  c: Integer;
  tickCycle: Integer;
begin
  while True do
  begin
    cycle := S32(cycleLimit);
    c := S32(0);
    while (c < 4) do
    begin
      tickCycle := S32(ctx.channels[c].tickCycle);
      if (cycle > tickCycle) then
      begin
        cycle := S32(tickCycle);
      end;
      c := S32(c + 1);
    end;
    if (cycle = cycleLimit) then
    begin
      Break;
    end;
    if (cycle = ctx.channels[2].tickCycle) then
    begin
      if ((((ctx.audctl and 4) <> 0) and (ctx.channels[0].delta > 0)) and (ctx.channels[0].mute = 0)) then
      begin
        PokeyChannel_Slope(ctx.channels[0], ctx, pokeys, cycle);
      end;
      PokeyChannel_DoTick(ctx.channels[2], ctx, pokeys, cycle, 2);
    end;
    if (cycle = ctx.channels[3].tickCycle) then
    begin
      if ((ctx.audctl and 8) <> 0) then
      begin
        ctx.channels[2].tickCycle := S32(Int64(cycle) + ctx.reloadCycles3);
      end;
      if ((((ctx.audctl and 2) <> 0) and (ctx.channels[1].delta > 0)) and (ctx.channels[1].mute = 0)) then
      begin
        PokeyChannel_Slope(ctx.channels[1], ctx, pokeys, cycle);
      end;
      PokeyChannel_DoTick(ctx.channels[3], ctx, pokeys, cycle, 3);
    end;
    if (cycle = ctx.channels[0].tickCycle) then
    begin
      if ((ctx.skctl and 136) = 8) then
      begin
        ctx.channels[1].tickCycle := S32(Int64(cycle) + ctx.channels[1].periodCycles);
      end;
      PokeyChannel_DoTick(ctx.channels[0], ctx, pokeys, cycle, 0);
    end;
    if (cycle = ctx.channels[1].tickCycle) then
    begin
      if ((ctx.audctl and 16) <> 0) then
      begin
        ctx.channels[0].tickCycle := S32(Int64(cycle) + ctx.reloadCycles1);
      end
      else
      begin
        if ((ctx.skctl and 8) <> 0) then
        begin
          ctx.channels[0].tickCycle := S32(Int64(cycle) + ctx.channels[0].periodCycles);
        end;
      end;
      PokeyChannel_DoTick(ctx.channels[1], ctx, pokeys, cycle, 1);
    end;
  end;
end;

procedure Pokey_InitMute(ctx: TPokey; cycle: Integer);
var
  init: Boolean;
  audctl: Integer;
begin
  init := ctx.init;
  audctl := S32(ctx.audctl);
  PokeyChannel_SetMute(ctx.channels[0], (init and ((audctl and 64) = 0)), 1, cycle);
  PokeyChannel_SetMute(ctx.channels[1], (init and ((audctl and 80) <> 80)), 1, cycle);
  PokeyChannel_SetMute(ctx.channels[2], (init and ((audctl and 32) = 0)), 1, cycle);
  PokeyChannel_SetMute(ctx.channels[3], (init and ((audctl and 40) <> 40)), 1, cycle);
end;

procedure Pokey_Initialize(ctx: TPokey; sampleRate: Integer);
var
  sr: Int64;
  c: Integer;
begin
  sr := sampleRate;
  ctx.deltaBufferLength := S32((((((sr * 312) * 114) div 1773447) + 32) + 2));
  SetLength(ctx.deltaBuffer, ctx.deltaBufferLength);
  ctx.trailing := S32(ctx.deltaBufferLength);
  c := S32(0);
  while (c < 4) do
  begin
    PokeyChannel_Initialize(ctx.channels[c]);
    c := S32(c + 1);
  end;
  ctx.audctl := S32(0);
  ctx.skctl := S32(3);
  ctx.irqst := S32(255);
  ctx.init := False;
  ctx.divCycles := S32(28);
  ctx.reloadCycles1 := S32(28);
  ctx.reloadCycles3 := S32(28);
  ctx.polyIndex := S32(60948015);
  ctx.iirAcc := S32(0);
  ctx.iirRate := S32((264600 div sampleRate));
  ctx.sumDACInputs := S32(0);
  Pokey_StartFrame(ctx);
end;

function Pokey_IsSilent(ctx: TPokey): Boolean;
var
  c: Integer;
begin
  c := S32(0);
  while (c < 4) do
  begin
    if ((ctx.channels[c].audc and 15) <> 0) then
    begin
      Exit(False);
    end;
    c := S32(c + 1);
  end;
  Exit(True);
end;

procedure Pokey_Mute(ctx: TPokey; mask: Integer);
var
  i: Integer;
begin
  i := S32(0);
  while (i < 4) do
  begin
    PokeyChannel_SetMute(ctx.channels[i], ((mask and S32((Int64(1) shl (i and 31)))) <> 0), 2, 0);
    i := S32(i + 1);
  end;
end;

function Pokey_Poke(ctx: TPokey; pokeys: TPokeyPair; addr: Integer; data: Integer; cycle: Integer): Integer;
var
  nextEventCycle: Integer;
  conditionValue6: Integer;
  c: Integer;
  i: Integer;
  t: Integer;
  init: Boolean;
  conditionValue13: Integer;
begin
  nextEventCycle := S32(8388608);
  case (addr and 15) of
    0:
      begin
        if (data = ctx.channels[0].audf) then
        begin
          Exit(nextEventCycle);
        end;
        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[0].audf := S32(data);
        case (ctx.audctl and 80) of
          0:
            begin
              ctx.channels[0].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          16:
            begin
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles1 := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          64:
            begin
              ctx.channels[0].periodCycles := S32(Int64(data) + 4);
            end;
          80:
            begin
              ctx.channels[1].periodCycles := S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles1 := S32(Int64(data) + 4);
            end;
        else
          begin
            abort();
          end;
        end;
        Exit(nextEventCycle);
      end;
    1:
      begin
        PokeyChannel_SetAudc(ctx.channels[0], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    2:
      begin
        if (data = ctx.channels[1].audf) then
        begin
          Exit(nextEventCycle);
        end;
        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[1].audf := S32(data);
        case (ctx.audctl and 80) of
          0, 64:
            begin
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          16:
            begin
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(data) shl (8 and 31))))) + 1));
            end;
          80:
            begin
              ctx.channels[1].periodCycles := S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(data) shl (8 and 31))))) + 7);
            end;
        else
          begin
            abort();
          end;
        end;
        Exit(nextEventCycle);
      end;
    3:
      begin
        PokeyChannel_SetAudc(ctx.channels[1], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    4:
      begin
        if (data = ctx.channels[2].audf) then
        begin
          Exit(nextEventCycle);
        end;
        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[2].audf := S32(data);
        case (ctx.audctl and 40) of
          0:
            begin
              ctx.channels[2].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          8:
            begin
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles3 := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          32:
            begin
              ctx.channels[2].periodCycles := S32(Int64(data) + 4);
            end;
          40:
            begin
              ctx.channels[3].periodCycles := S32(Int64(S32(Int64(data) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles3 := S32(Int64(data) + 4);
            end;
        else
          begin
            abort();
          end;
        end;
        Exit(nextEventCycle);
      end;
    5:
      begin
        PokeyChannel_SetAudc(ctx.channels[2], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    6:
      begin
        if (data = ctx.channels[3].audf) then
        begin
          Exit(nextEventCycle);
        end;
        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.channels[3].audf := S32(data);
        case (ctx.audctl and 40) of
          0, 32:
            begin
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(data) + 1));
            end;
          8:
            begin
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(data) shl (8 and 31))))) + 1));
            end;
          40:
            begin
              ctx.channels[3].periodCycles := S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(data) shl (8 and 31))))) + 7);
            end;
        else
          begin
            abort();
          end;
        end;
        Exit(nextEventCycle);
      end;
    7:
      begin
        PokeyChannel_SetAudc(ctx.channels[3], ctx, pokeys, data, cycle);
        Exit(nextEventCycle);
      end;
    8:
      begin
        if (data = ctx.audctl) then
        begin
          Exit(nextEventCycle);
        end;
        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.audctl := S32(data);
        if ((data and 1) <> 0) then
        begin
          conditionValue6 := 114;
        end
        else
        begin
          conditionValue6 := 28;
        end;
        ctx.divCycles := S32(conditionValue6);
        case (data and 80) of
          0:
            begin
              ctx.channels[0].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[0].audf) + 1));
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[1].audf) + 1));
            end;
          16:
            begin
              ctx.channels[0].periodCycles := S32((Int64(ctx.divCycles) shl (8 and 31)));
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles1 := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[0].audf) + 1));
            end;
          64:
            begin
              ctx.channels[0].periodCycles := S32(Int64(ctx.channels[0].audf) + 4);
              ctx.channels[1].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[1].audf) + 1));
            end;
          80:
            begin
              ctx.channels[0].periodCycles := S32(256);
              ctx.channels[1].periodCycles := S32(Int64(S32(Int64(ctx.channels[0].audf) + S32((Int64(ctx.channels[1].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles1 := S32(Int64(ctx.channels[0].audf) + 4);
            end;
        else
          begin
            abort();
          end;
        end;
        case (data and 40) of
          0:
            begin
              ctx.channels[2].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[2].audf) + 1));
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[3].audf) + 1));
            end;
          8:
            begin
              ctx.channels[2].periodCycles := S32((Int64(ctx.divCycles) shl (8 and 31)));
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 1));
              ctx.reloadCycles3 := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[2].audf) + 1));
            end;
          32:
            begin
              ctx.channels[2].periodCycles := S32(Int64(ctx.channels[2].audf) + 4);
              ctx.channels[3].periodCycles := S32(Int64(ctx.divCycles) * S32(Int64(ctx.channels[3].audf) + 1));
            end;
          40:
            begin
              ctx.channels[2].periodCycles := S32(256);
              ctx.channels[3].periodCycles := S32(Int64(S32(Int64(ctx.channels[2].audf) + S32((Int64(ctx.channels[3].audf) shl (8 and 31))))) + 7);
              ctx.reloadCycles3 := S32(Int64(ctx.channels[2].audf) + 4);
            end;
        else
          begin
            abort();
          end;
        end;
        Pokey_InitMute(ctx, cycle);
        Exit(nextEventCycle);
      end;
    9:
      begin
        c := S32(0);
        while (c < 4) do
        begin
          PokeyChannel_DoStimer(ctx.channels[c], cycle);
          c := S32(c + 1);
        end;
        Exit(nextEventCycle);
      end;
    14:
      begin
        ctx.irqst := S32(Int64(ctx.irqst) or (data xor 255));
        i := S32(3);
        while True do
        begin
          if (((data and ctx.irqst) and S32(Int64(i) + 1)) <> 0) then
          begin
            if (ctx.channels[i].timerCycle = 8388608) then
            begin
              t := S32(ctx.channels[i].tickCycle);
              while (t < cycle) do
              begin
                t := S32(Int64(t) + ctx.channels[i].periodCycles);
              end;
              ctx.channels[i].timerCycle := S32(t);
              if (nextEventCycle > t) then
              begin
                nextEventCycle := S32(t);
              end;
            end;
          end
          else
          begin
            ctx.channels[i].timerCycle := S32(8388608);
          end;
          if (i = 0) then
          begin
            Break;
          end;
          i := S32(Sar32(i, 1));
        end;
        Exit(nextEventCycle);
      end;
    15:
      begin
        if (data = ctx.skctl) then
        begin
          Exit(nextEventCycle);
        end;
        Pokey_GenerateUntilCycle(ctx, pokeys, cycle);
        ctx.skctl := S32(data);
        init := ((data and 3) = 0);
        if (ctx.init and not (init)) then
        begin
          if ((ctx.audctl and 128) <> 0) then
          begin
            conditionValue13 := 237614;
          end
          else
          begin
            conditionValue13 := 60948014;
          end;
          ctx.polyIndex := S32(Int64(conditionValue13) - cycle);
        end;
        ctx.init := init;
        Pokey_InitMute(ctx, cycle);
        PokeyChannel_SetMute(ctx.channels[2], ((data and 16) <> 0), 4, cycle);
        PokeyChannel_SetMute(ctx.channels[3], ((data and 16) <> 0), 4, cycle);
        Exit(nextEventCycle);
      end;
  else
    begin
      Exit(nextEventCycle);
    end;
  end;
  Exit(S32(nextEventCycle));
end;

procedure Pokey_StartFrame(ctx: TPokey);
begin
  for var copyIndex := 0 to (S32(Int64(S32(Int64(ctx.deltaBufferLength) - ctx.trailing)) * 4)) div 4 - 1 do
    ctx.deltaBuffer[0 + copyIndex] := ctx.deltaBuffer[ctx.trailing + copyIndex];
  for var clearIndex := 0 to (S32(Int64(ctx.trailing) * 4)) div 4 - 1 do
    ctx.deltaBuffer[S32(Int64(ctx.deltaBufferLength) - ctx.trailing) + clearIndex] := 0;
end;

function Pokey_StoreSample(ctx: TPokey; buffer: TBytes; bufferOffset: Integer; i: Integer; format: TASAPSampleFormat): Integer;
var
  sample: Integer;
begin
  ctx.iirAcc := S32(Int64(ctx.iirAcc) + S32(Int64(ctx.deltaBuffer[i]) - Sar32(S32(Int64(ctx.iirRate) * ctx.iirAcc), 11)));
  sample := EnsureRange(Sar32(ctx.iirAcc, 11), -32767, 32767);
  case format of
    ASAPSampleFormat_U8:
      begin
        buffer[bufferOffset] := U8(Sar32(sample, 8) + 128);
        Inc(bufferOffset);
      end;
    ASAPSampleFormat_S16_L_E:
      begin
        buffer[bufferOffset] := U8(sample);
        buffer[bufferOffset + 1] := U8(Sar32(sample, 8));
        Inc(bufferOffset, 2);
      end;
    ASAPSampleFormat_S16_B_E:
      begin
        buffer[bufferOffset] := U8(Sar32(sample, 8));
        buffer[bufferOffset + 1] := U8(sample);
        Inc(bufferOffset, 2);
      end;
  end;
  Result := bufferOffset;
end;

end.
