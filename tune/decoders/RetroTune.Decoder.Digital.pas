unit RetroTune.Decoder.Digital;

interface

implementation

uses
  System.SysUtils, System.Math, RetroTune.Decoder, RetroTune.Digital.Module,
  RetroTune.Binary, ZX.Sound.DAC;

type
  TChannelState = record
    Note, NoteSlide, Sample, Volume, Slide, Sliding, Ornament, OrnamentPos: Integer;
    Period, Counter, Direction, Effect, FloatStep, VibStep, VibPeriod, ArpStep, ArpPeriod, NoteStep, NotePeriod, DoublePeriod, AttackPeriod, AttackLimit, DecayPeriod, DecayLimit: Integer;
    OldCell: TDigitalCell;
    Backup: TZXDACVoice;
    BackupNote, BackupSlide, BackupVolume: Integer;
  end;

  TDigitalDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FModule: TDigitalModule;
    FDAC: TZXSampleDAC;
    FInfo: TTuneInfo;
    FState: array[0..3] of TChannelState;
    FRow, FQuirk, FTempo, FRemaining, FTicks: Integer;
    procedure Tick;
    procedure Cell(C: Integer; const Data: TDigitalCell; Effects: Boolean = True);
    procedure Effect(C: Integer);
  public
    constructor Create(const Data: TBytes; Kind: TDigitalKind);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TDigitalDecoder.Create(const Data: TBytes; Kind: TDigitalKind);
const
  Names: array[TDigitalKind] of string = ('CHI', 'DMM', 'DST', 'SQD', 'STR', 'ET1', 'PDT');
begin
  inherited Create;
  FModule := ParseDigitalModule(Data, Kind);
  FInfo.FormatName := Names[Kind];
  FInfo.Title := FModule.Title;
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  FInfo.Details := Format('%s %s, %d sample voices, %d Hz base rate', [Names[Kind], FModule.Version, FModule.Channels, FModule.BaseRate]);
  var Tempo := FModule.Tempo;
  FTicks := 0;
  for var Row in FModule.Rows do
  begin
    if Row.Tempo > 0 then
      Tempo := Row.Tempo;
    Inc(FTicks, Tempo);
    if FTicks > 90000 then
      raise EArgumentException.Create('Digital song exceeds frame limit');
  end;
  FInfo.TrackDurations := [FTicks / 50.0];
  FDAC := TZXSampleDAC.Create(FModule.Samples, FModule.Channels);
  SelectTrack(0);
end;

destructor TDigitalDecoder.Destroy;
begin
  FDAC.Free;
  inherited;
end;

function TDigitalDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TDigitalDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Digital track');
  FDAC.Reset;
  FRow := 0;
  FQuirk := 0;
  FRemaining := 0;
  FTempo := FModule.Tempo;
  for var C := 0 to 3 do
  begin
    FState[C] := Default(TChannelState);
    FState[C].Volume := 15;
    FState[C].FloatStep := 1;
    FState[C].VibStep := 3;
    FState[C].VibPeriod := 4;
    FState[C].ArpStep := 18;
    FState[C].ArpPeriod := 1;
    FState[C].NoteStep := 12;
    FState[C].NotePeriod := 2;
    FState[C].DoublePeriod := 3;
    FState[C].AttackPeriod := 1;
    FState[C].AttackLimit := 15;
    FState[C].DecayPeriod := 1;
    FState[C].DecayLimit := 1;
    if FModule.Kind in [dkSQD, dkET1] then
      FState[C].Volume := 16;
  end;
end;

procedure TDigitalDecoder.Cell(C: Integer; const Data: TDigitalCell; Effects: Boolean);
begin
  if Data.Note = -2 then
  begin
    FDAC.Voices[C].Enabled := False;
    FDAC.Voices[C].Position := 0;
    FState[C].Sliding := 0;
    FState[C].NoteSlide := 0;
  end
  else if Data.Note >= 0 then
  begin
    FState[C].Note := Data.Note;
    FDAC.Voices[C].Enabled := True;
    if FModule.Kind <> dkDMM then
      FDAC.Voices[C].Position := 0;
    FState[C].Sliding := 0;
    FState[C].NoteSlide := 0;
    if FModule.Kind = dkDMM then
    begin
      FState[C].Counter := 0;
      FState[C].VibStep := 0;
      FState[C].ArpStep := 0;
    end;
  end;
  if Data.Sample >= 0 then
  begin
    FState[C].Sample := Data.Sample;
    FDAC.Voices[C].Sample := Data.Sample;
    FDAC.Voices[C].Position := 0;
  end;
  // Extreme Tracker resets attenuation on each nonempty channel cell.
  if (FModule.Kind = dkET1) and ((Data.RawNote <> 0) or (Data.RawParam <> 0)) then
    FState[C].Volume := 16;
  if Data.Volume >= 0 then
    FState[C].Volume := Data.Volume;
  if Data.Offset >= 0 then
    FDAC.Voices[C].Position := Data.Offset;
  case FModule.Kind of
    dkCHI:
      FState[C].Slide := Data.Slide;
    dkET1:
      if Data.RawNote shr 6 = 1 then
        FState[C].Slide := Data.Slide;
    dkPDT:
      if (Data.Note >= 0) and (Data.Ornament >= 0) then
      begin
        FState[C].Ornament := Data.Ornament;
        FState[C].OrnamentPos := 0;
      end;
    dkSQD:
      begin
        if Data.RawNote = 64 then
        begin
          FState[C].Period := Data.RawParam;
          FState[C].Counter := Data.RawParam;
        end;
        if Data.Note >= 0 then
          FState[C].Direction := Data.Slide;
      end;
    dkDMM:
      if Effects then
      begin
        var N := Integer(Data.RawNote);
        var P := Integer(Data.RawParam);
        var E := Integer(Data.RawEffect);
        if N < 62 then
        begin
          if E = 0 then
            Exit;
          FState[C].OldCell := Data;
          case E of
            1, 2:
              begin
                FState[C].Effect := 1;
                FState[C].FloatStep := 1;
                if E = 2 then
                  FState[C].FloatStep := -1;
              end;
            3, 4:
              FState[C].Effect := E;
            5, 6:
              begin
                FState[C].Effect := 5;
                FState[C].NoteStep := 1;
                if E = 6 then
                  FState[C].NoteStep := -1;
              end;
            7, 8, 9:
              FState[C].Effect := E;
            15:
              FState[C].Effect := 0;
          else
            var Mix := (E - 10) mod 64;
            FState[C].Backup := FDAC.Voices[C];
            FState[C].BackupNote := FState[C].Note;
            FState[C].BackupSlide := FState[C].Sliding;
            FState[C].BackupVolume := FState[C].Volume;
            Cell(C, FModule.Mixins[Mix], False);
            FState[C].Effect := 10;
            FState[C].Period := FModule.MixPeriods[Mix];
          end;
        end
        else
          case N of
            63:
              FState[C].FloatStep := EnsureRange(FState[C].FloatStep * P, -3072, 3072);
            64:
              begin
                FState[C].VibStep := P;
                FState[C].VibPeriod := E;
              end;
            65:
              begin
                FState[C].ArpStep := P;
                FState[C].ArpPeriod := E;
              end;
            66:
              begin
                FState[C].NoteStep := EnsureRange(FState[C].NoteStep * P, -96, 96);
                FState[C].NotePeriod := E;
              end;
            67:
              FState[C].DoublePeriod := P;
            68:
              begin
                FState[C].AttackLimit := P and 15;
                FState[C].AttackPeriod := E;
              end;
            69:
              begin
                FState[C].DecayLimit := P and 15;
                FState[C].DecayPeriod := E;
              end;
          end;
      end;
  end;
end;

procedure TDigitalDecoder.Effect(C: Integer);
const
  Steps: array[0..59] of Integer = (44, 47, 50, 53, 56, 59, 63, 66, 70, 74, 79, 83, 88, 94, 99, 105, 111, 118, 125, 133, 140, 149, 158, 167, 177, 187, 199, 210, 223, 236, 250, 265, 281, 297, 315, 334, 354, 375, 397, 421, 446, 472, 500, 530, 561, 595, 630, 668, 707, 749, 794, 841, 891, 944, 1001, 1060, 1123, 1189, 1216, 1335);

  procedure FloatBy(Step: Integer);
  begin
    var Next := Steps[EnsureRange(FState[C].Note + FState[C].NoteSlide, 0, 59)] + FState[C].Sliding + Step;
    if (Next <= 0) or (Next >= $C00) then
      FState[C].Effect := 0
    else
    begin
      Inc(FState[C].Sliding, Step);
      FState[C].NoteSlide := 0;
    end;
  end;

begin
  case FModule.Kind of
    dkCHI, dkET1:
      FState[C].Sliding := EnsureRange(FState[C].Sliding + FState[C].Slide, -65536, 65536);
    dkSQD:
      if (FState[C].Direction <> 0) and (FState[C].Period > 0) then
      begin
        Dec(FState[C].Counter);
        if FState[C].Counter <= 0 then
        begin
          FState[C].Counter := FState[C].Period;
          FState[C].Volume := EnsureRange(FState[C].Volume + FState[C].Direction, 0, 16);
        end;
      end;
    dkPDT:
      begin
        var O := FState[C].Ornament;
        var Size := Length(FModule.Ornaments[O].Notes);
        if Size > 0 then
        begin
          Inc(FState[C].OrnamentPos);
          if FState[C].OrnamentPos = Size then
            FState[C].OrnamentPos := FModule.Ornaments[O].Loop;
        end;
      end;
    dkDMM:
      begin
        var Period: Integer;
        case FState[C].Effect of
          1:
            begin
              FloatBy(FState[C].FloatStep);
              Exit;
            end;
          3:
            Period := FState[C].VibPeriod;
          4:
            Period := FState[C].ArpPeriod;
          5:
            Period := FState[C].NotePeriod;
          7:
            Period := FState[C].DoublePeriod;
          8:
            Period := FState[C].AttackPeriod;
          9:
            Period := FState[C].DecayPeriod;
          10:
            Period := FState[C].Period;
        else
          Exit;
        end;
        Inc(FState[C].Counter);
        if (Period = 0) or (FState[C].Counter <> Period) then
          Exit;
        FState[C].Counter := 0;
        case FState[C].Effect of
          3:
            begin
              FState[C].VibStep := -FState[C].VibStep;
              FloatBy(FState[C].VibStep);
            end;
          4:
            begin
              FState[C].ArpStep := -FState[C].ArpStep;
              FState[C].NoteSlide := EnsureRange(FState[C].NoteSlide + FState[C].ArpStep, -96, 96);
              FState[C].Sliding := 0;
            end;
          5:
            begin
              FState[C].NoteSlide := EnsureRange(FState[C].NoteSlide + FState[C].NoteStep, -96, 96);
              FState[C].Sliding := 0;
            end;
          7:
            begin
              Cell(C, FState[C].OldCell, False);
              FState[C].Effect := 0;
            end;
          8:
            if FState[C].Volume < FState[C].AttackLimit then
              Inc(FState[C].Volume)
            else
              FState[C].Effect := 0;
          9:
            if FState[C].Volume > FState[C].DecayLimit then
              Dec(FState[C].Volume)
            else
              FState[C].Effect := 0;
          10:
            begin
              FDAC.Voices[C] := FState[C].Backup;
              FState[C].Note := FState[C].BackupNote;
              FState[C].Sliding := FState[C].BackupSlide;
              FState[C].Volume := FState[C].BackupVolume;
              FDAC.Voices[C].Position := FDAC.Voices[C].Position + FDAC.Voices[C].Rate * Period / 50;
              FState[C].Effect := 0;
            end;
        end;
      end;
  end;
end;

procedure TDigitalDecoder.Tick;
begin
  if FRow >= Length(FModule.Rows) then
    Exit;
  for var C := 0 to FModule.Channels - 1 do
    Effect(C);
  if FQuirk = 0 then
  begin
    if FModule.Rows[FRow].Tempo > 0 then
      FTempo := FModule.Rows[FRow].Tempo;
    for var C := 0 to FModule.Channels - 1 do
    begin
      if FModule.Kind = dkCHI then
      begin
        FState[C].Sliding := 0;
        FState[C].Slide := 0;
      end;
      Cell(C, FModule.Rows[FRow].Cells[C]);
    end;
  end;
  for var C := 0 to FModule.Channels - 1 do
  begin
    var Note := FState[C].Note + FState[C].NoteSlide;
    if FModule.Kind = dkPDT then
    begin
      var O := FState[C].Ornament;
      if FState[C].OrnamentPos < Length(FModule.Ornaments[O].Notes) then
        Inc(Note, FModule.Ornaments[O].Notes[FState[C].OrnamentPos]);
    end;
    var Rate := FModule.BaseRate * Power(2, EnsureRange(Note, 0, 95) / 12.0);
    if FModule.SlideScale <> 0 then
      Rate := Max(0, Rate + Trunc(FState[C].Sliding * FModule.SlideScale) * FModule.BaseRate / 32.7);
    FDAC.Voices[C].Rate := Rate;
    var Scale := 15;
    if FModule.Kind in [dkSQD, dkET1] then
      Scale := 16;
    FDAC.Voices[C].Gain := EnsureRange(FState[C].Volume / Double(Scale), 0.0, 1.0);
  end;
  Inc(FQuirk);
  if FQuirk >= FTempo then
  begin
    Inc(FRow);
    FQuirk := 0;
  end;
end;

function TDigitalDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while Result < Frames do
  begin
    if FRemaining = 0 then
    begin
      if FRow = Length(FModule.Rows) then
        Break;
      Tick;
      FRemaining := 882;
    end;
    FDAC.Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
    Inc(Result);
    Dec(FRemaining);
  end;
end;

function OpenCHI(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkCHI);
end;

function OpenDMM(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkDMM);
end;

function OpenDST(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkDST);
end;

function OpenSQD(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkSQD);
end;

function OpenSTR(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkSTR);
end;

function OpenET1(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkET1);
end;

function OpenPDT(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, dkPDT);
end;

function OpenM(const Data: TBytes): ITuneDecoder;
begin
  Result := TDigitalDecoder.Create(Data, DetectDigitalModule(Data));
end;

initialization
  TTuneDecoders.RegisterFormat('.chi', 'Chip Tracker', OpenCHI);
  TTuneDecoders.RegisterFormat('.dmm', 'Digital Music Maker', OpenDMM);
  TTuneDecoders.RegisterFormat('.dst', 'Digital Studio', OpenDST);
  TTuneDecoders.RegisterFormat('.sqd', 'SQ Digital Tracker', OpenSQD);
  TTuneDecoders.RegisterFormat('.str', 'Sample Tracker', OpenSTR);
  TTuneDecoders.RegisterFormat('.et1', 'Extreme Tracker', OpenET1);
  TTuneDecoders.RegisterFormat('.pdt', 'ProDigiTracker', OpenPDT);
  TTuneDecoders.RegisterFormat('.d', 'Extreme Tracker', OpenET1);
  TTuneDecoders.RegisterFormat('.m', 'Extreme / ProDigiTracker', OpenM);

end.

