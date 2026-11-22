unit NES.Audio.Jaleco;

interface

uses
  System.SysUtils, NES.Types, NES.State, Core.Storage, HW.Sound.UPD7756,
  NES.Audio.Recordings;

function JalecoRecordingPack(MapperId: Integer; const Sha1: string): string;

type
  TJalecoSpeech = class
  private
    type
      TPlayback = packed record
        ResetHigh, StartActive, Playing: Boolean;
        SelectedTrack, PlayingTrack: Byte;
        ResetTicks, RecoveryTicks, Phase, Position: Integer;
        Sample: SmallInt;
      end;
  private
    FChip: TUpd7756;
    FRecordings: TNesSpeechRecordings;
    FHasAudio: Boolean;
    FState: TPlayback;
    FCpuHz, FResetDelay, FRecoveryDelay: Integer;
    procedure Stop;
    procedure Start;
    procedure ClockRecording;
  public
    constructor Create(const Rom: TBytes);
    destructor Destroy; override;
    procedure LoadRecordings(const Storage: IStorage; const RomName, Pack: string);
    procedure Reset(ResetHigh: Boolean);
    procedure SetRegion(Region: TNesRegion);
    procedure WritePins(Track: Byte; ResetHigh, StartActive: Boolean);
    procedure Clock;
    function Output: Double;
    procedure SerializeState(State: TNesStateArchive);
  end;

implementation

uses
  System.Classes, Core.Snapshots, NES.Consts, NES.Mapper;

function JalecoRecordingPack(MapperId: Integer; const Sha1: string): string;
begin
  Result := '';
  case MapperId of
    MAPPER_JALECO_SS88006:
      if Sha1 = '1ab6164393db3e3ddacb3db506171b0e5387ad4e' then
        Result := 'terao'
      else if (Sha1 = '3fe256cd3d4fc47c83ccb7847e1a58a99b1323f4') or
        (Sha1 = '0f4a2534c1a11309079e7f488f71e72e75a04bc8') or
        (Sha1 = '16ca1128f019c9de9f152f7cb7f06fba30b6b5ab') then
        Result := 'moepro88';
    MAPPER_JALECO_JF17:
      if Sha1 = 'cb130f4e4cae6ddb112cfe96024be1d3292dd84b' then
        Result := 'mptennis';
    MAPPER_JALECO_JF19:
      if Sha1 = '493398472dff732c8ef99a123b51f70dcd33b291' then
        Result := 'moepro88';
  end;
end;

constructor TJalecoSpeech.Create(const Rom: TBytes);
begin
  inherited Create;
  if Length(Rom) <> 0 then
  begin
    FChip := TUpd7756.Create(Rom);
    FHasAudio := True;
  end;
  SetRegion(TNesRegion.NTSC);
end;

destructor TJalecoSpeech.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TJalecoSpeech.LoadRecordings(const Storage: IStorage; const RomName, Pack: string);
begin
  if (FChip = nil) and (Pack <> '') then
    FHasAudio := LoadSpeechRecordings(Storage, RomName, Pack, Length(FRecordings), FRecordings) or FHasAudio;
end;

procedure TJalecoSpeech.Reset(ResetHigh: Boolean);
begin
  FState := Default(TPlayback);
  FState.ResetHigh := ResetHigh;
  if FChip <> nil then
    FChip.Reset;
end;

procedure TJalecoSpeech.SetRegion(Region: TNesRegion);
begin
  FCpuHz := CpuFrequency(Region);
  FResetDelay := (FCpuHz * Int64(19) + 999999) div 1000000;
  // The 23-cycle NTSC recovery interval belongs to the speech chip.
  FRecoveryDelay := (FCpuHz * Int64(23) + CpuFrequency(TNesRegion.NTSC) - 1) div
    CpuFrequency(TNesRegion.NTSC);
end;

procedure TJalecoSpeech.Stop;
begin
  if FChip <> nil then
    FChip.Reset;
  FState.Playing := False;
  FState.Sample := 0;
end;

procedure TJalecoSpeech.Start;
begin
  if FChip <> nil then
  begin
    FChip.Start(FState.SelectedTrack);
    Exit;
  end;
  if FState.Playing or (Length(FRecordings[FState.SelectedTrack].Samples) = 0) then
    Exit;
  FState.PlayingTrack := FState.SelectedTrack;
  FState.Phase := 0;
  FState.Position := 0;
  FState.Sample := 0;
  FState.Playing := True;
end;

procedure TJalecoSpeech.WritePins(Track: Byte; ResetHigh, StartActive: Boolean);
begin
  if not FHasAudio then
    Exit;

  if ResetHigh and not FState.ResetHigh then
  begin
    FState.RecoveryTicks := FRecoveryDelay;
    FState.ResetTicks := 0;
  end;
  FState.ResetHigh := ResetHigh;
  FState.StartActive := StartActive;
  FState.SelectedTrack := Track and 63;
  if ResetHigh and StartActive and (FState.RecoveryTicks = 0) then
    Start;
end;

procedure TJalecoSpeech.ClockRecording;
begin
  Inc(FState.Phase, FRecordings[FState.PlayingTrack].Rate);
  if FState.Phase < FCpuHz then
    Exit;
  Dec(FState.Phase, FCpuHz);
  if FState.Position = Length(FRecordings[FState.PlayingTrack].Samples) then
    Stop
  else
  begin
    FState.Sample := FRecordings[FState.PlayingTrack].Samples[FState.Position];
    Inc(FState.Position);
  end;
end;

procedure TJalecoSpeech.Clock;
begin
  if not FHasAudio then
    Exit;
  if not FState.ResetHigh then
  begin
    if FState.ResetTicks = FResetDelay then
      Exit;
    Inc(FState.ResetTicks);
    if FState.ResetTicks = FResetDelay then
    begin
      Stop;
      Exit;
    end;
  end
  else if FState.RecoveryTicks > 0 then
    Dec(FState.RecoveryTicks);

  if FChip <> nil then
    FChip.Clock(FCpuHz)
  else if FState.Playing then
    ClockRecording;
  if FState.ResetHigh and FState.StartActive and (FState.RecoveryTicks = 0) then
    if ((FChip <> nil) and not FChip.Playing) or ((FChip = nil) and not FState.Playing) then
      Start;
end;

function TJalecoSpeech.Output: Double;
begin
  if FChip <> nil then
    Exit(FChip.Output * (1.0 / 131072.0));
  Result := FState.Sample * (1.0 / 131072.0);
end;

procedure TJalecoSpeech.SerializeState(State: TNesStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  if State.Loading then
  begin
    if (FState.SelectedTrack > High(FRecordings)) or (FState.PlayingTrack > High(FRecordings)) or
      (Cardinal(FState.Phase) >= Cardinal(FCpuHz)) or (Cardinal(FState.Position) > 960000) or
      (Cardinal(FState.RecoveryTicks) > Cardinal(FRecoveryDelay)) or
      (Cardinal(FState.ResetTicks) > Cardinal(FResetDelay)) then
      raise EReadError.Create('Invalid Jaleco voice state');
    if FState.Playing and ((Length(FRecordings[FState.PlayingTrack].Samples) = 0) or
      (FState.Position > Length(FRecordings[FState.PlayingTrack].Samples))) then
      Stop;
  end;
  if FChip <> nil then
    State.SharedFields(
      procedure(Archive: TStateArchive)
      begin
        FChip.SerializeState(Archive, FCpuHz);
      end);
end;

end.

