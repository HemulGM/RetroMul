unit Audio.ATRAC3Plus;

// Native ATRAC3+ decoder. The translated codec is GPL-3.0-or-later.
interface

uses
  System.SysUtils, Audio.ATRAC3Plus.Decoder;

type
  TATRAC3PlusDecoder = class
  private
    FContext: TATContext;
    FChannels, FOutputChannels: Integer;
    procedure Initialize;
  public
    constructor Create(Channels, OutputChannels: Integer);
    destructor Destroy; override;
    procedure Reset;
    function Decode(const Packet: TBytes): TArray<SmallInt>;
  end;

implementation

uses
  System.Math, Audio.ATRAC3Plus.Primitives;

constructor TATRAC3PlusDecoder.Create(Channels, OutputChannels: Integer);
begin
  inherited Create;
  if not (Channels in [1, 2]) or not (OutputChannels in [1, 2]) then
    raise EATRACData.Create('ATRAC3+: unsupported channel count');
  FChannels := Channels;
  FOutputChannels := OutputChannels;
  Initialize;
end;

destructor TATRAC3PlusDecoder.Destroy;
begin
  FContext.Free;
  inherited;
end;

procedure TATRAC3PlusDecoder.Initialize;
begin
  FContext := TATContext.Create;
  FContext.OutputChannels := FOutputChannels;
  FContext.Dsp := TATAtrac3plusDsp.Create;
  FContext.MDCTCtx := TATIMDCT.Create;
  FContext.Dsp.InitIMDCT(FContext.MDCTCtx);
  FContext.IPQFDctCtx := TATIMDCT.Create;
  // Normalized 32-point inverse transform. No empirical gain adjustment.
  FContext.IPQFDctCtx.MDCTInit(5, True, 32.0 / 32768.0);
  TATAtrac3plusDsp.InitWaveSynth;
  FContext.GaincCtx := TATAtrac.Create;
  FContext.GaincCtx.InitGainCompensation(6, 2);
  for var I := 0 to 1 do
  begin
    FContext.ChannelUnits[I] := TATChannelUnit.Create;
    FContext.ChannelUnits[I].SetDsp(FContext.Dsp);
  end;
end;

procedure TATRAC3PlusDecoder.Reset;
begin
  FreeAndNil(FContext);
  Initialize;
end;

function TATRAC3PlusDecoder.Decode(const Packet: TBytes): TArray<SmallInt>;
begin
  if Length(Packet) = 0 then
    raise EATRACData.Create('ATRAC3+: empty packet');
  SetLength(Result, 2048 * FOutputChannels);
  var Reader := TATBits.Create(Packet);
  try
    if Reader.ReadBool then
      raise EATRACData.Create('ATRAC3+: invalid start bit');
    var Channels := 0;
    var Block := 0;
    var Terminated := False;
    while Reader.GetBitsLeft >= 2 do
    begin
      var Kind := Reader.Read(2);
      if Kind = 3 then
      begin
        Terminated := True;
        Break;
      end;
      if Kind = 2 then
        raise EATRACData.Create('ATRAC3+: extension channel unit is not supported');
      var Count := Kind + 1;
      if (Channels + Count > FChannels) or (Block >= 2) then
        raise EATRACData.Create('ATRAC3+: excess channels');
      var UnitData := FContext.ChannelUnits[Block];
      UnitData.SetBitReader(Reader);
      UnitData.Ctx.UnitType := Kind;
      UnitData.SetNumChannels(Count);
      if UnitData.Decode <> 0 then
        raise EATRACData.Create('ATRAC3+: invalid spectral data');
      UnitData.DecodeResidualSpectrum(FContext.Samples);
      UnitData.ReconstructFrame(FContext);
      for var Channel := 0 to Count - 1 do
        for var I := 0 to 2047 do
        begin
          var Value := SmallInt(EnsureRange(Round(FContext.OutpBuf[Channel][I] * 32768), -32768, 32767));
          var Dest := Channels + Channel;
          if Dest < FOutputChannels then
            Result[I * FOutputChannels + Dest] := Value;
          if (FChannels = 1) and (FOutputChannels = 2) then
            Result[I * 2 + 1] := Value;
        end;
      Inc(Channels, Count);
      Inc(Block);
    end;
    if not Terminated or (Channels <> FChannels) then
      raise EATRACData.Create('ATRAC3+: incomplete channel units');
  finally
    for var I := 0 to 1 do
      FContext.ChannelUnits[I].SetBitReader(nil);
    Reader.Free;
  end;
end;

end.

