unit A5200.ASAP.Types;

interface

uses
  System.SysUtils, A5200.POKEY.Types;

type
  TASAP = class;

  TASAPModuleType = Integer;

  TNmiStatus = Integer;

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

implementation

constructor TCpu6502.Create;
begin
  inherited;
  SetLength(memory, 65536);
end;

destructor TCpu6502.Destroy;
begin
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

end.

