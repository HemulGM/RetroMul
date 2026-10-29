unit A5200.POKEY.Types;

interface

uses
  System.SysUtils;

type
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

  TASAPSampleFormat = Integer;

const
  ASAPSampleFormat_U8 = 0;
  ASAPSampleFormat_S16_L_E = 1;
  ASAPSampleFormat_S16_B_E = 2;
  Pokey_COMPRESSED_SUMS: array[0..60] of SmallInt = (
    0, 35, 73, 111, 149, 189, 228, 266, 304, 342, 379, 415, 450, 484, 516, 546, 575, 602, 628, 652,
    674, 695, 715, 733, 750, 766, 782, 796, 809, 822, 834, 846, 856, 867, 876, 886, 894, 903, 911,
    918, 926, 933, 939, 946, 952, 958, 963, 969, 974, 979, 984, 988, 993, 997, 1001, 1005, 1009, 1013, 1016, 1019, 1023);

implementation

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

end.

