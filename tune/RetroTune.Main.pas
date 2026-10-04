unit RetroTune.Main;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Filter.Effects, FMX.ListBox, FMX.Controls.Presentation, RetroTune.Decoder,
  RetroTune.Player, RetroTune.Spectrum, FMX.Layouts, FMX.Objects;

type
  TFormMain = class(TForm)
    ButtonOpen: TButton;
    ButtonPlay: TButton;
    ButtonStop: TButton;
    ButtonPrevious: TButton;
    ButtonNext: TButton;
    LabelTitle: TLabel;
    LabelArtist: TLabel;
    LabelCopyright: TLabel;
    LabelDetails: TLabel;
    LabelTrack: TLabel;
    LabelStatus: TLabel;
    LabelVolume: TLabel;
    ComboTracks: TComboBox;
    TrackBarVolume: TTrackBar;
    TrackBarPosition: TTrackBar;
    LayoutTimeline: TLayout;
    LabelElapsed: TLabel;
    LabelDuration: TLabel;
    PlaybackTimer: TTimer;
    OpenDialog: TOpenDialog;
    StyleBookWinUI3: TStyleBook;
    PanelBackground: TPanel;
    PanelNowPlaying: TPanel;
    PanelArtwork: TPanel;
    PanelTransport: TPanel;
    PanelSpectrum: TPanel;
    LayoutContent: TLayout;
    LayoutHeader: TLayout;
    LayoutMetadata: TLayout;
    LayoutFooter: TLayout;
    LayoutPlayback: TLayout;
    LayoutVolume: TLayout;
    LayoutSpectrumHeader: TLayout;
    LayoutFrequency: TLayout;
    LabelBrand: TLabel;
    LabelTagline: TLabel;
    LabelMusicIcon: TLabel;
    LabelSpectrum: TLabel;
    LabelLowFrequency: TLabel;
    LabelHighFrequency: TLabel;
    ComboSpectrum: TComboBox;
    SpectrumPaintBox: TPaintBox;
    procedure SpectrumChange(Sender: TObject);
    procedure SpectrumPaint(Sender: TObject; Canvas: TCanvas);
    procedure FormCreate(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure PlayClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure TrackChange(Sender: TObject);
    procedure VolumeChange(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure PositionChange(Sender: TObject);
    procedure PositionTracking(Sender: TObject);
  private
    FPlayer: TTunePlayer;
    FInfo: TTuneInfo;
    FUpdating: Boolean;
    FBands: TTuneSpectrum;
    FStereoBands: array[0..1] of TTuneSpectrum;
    FStereoPCM: TTuneStereoWindow;
    FStereoLevels: TTuneStereoLevels;
    FPeaks: TTuneSpectrum;
    FPeakHold: array[0..TuneSpectrumBands - 1] of Integer;
    FHistory: TBitmap;
    procedure UpdateSpectrum;
    procedure ResetSpectrum;
    procedure LoadTune(const Path: string);
  public
    destructor Destroy; override;
  end;

var
  FormMain: TFormMain;

implementation

uses
  System.IOUtils, System.Math, System.StrUtils, RetroTune.Decoder.NSF,
  RetroTune.Decoder.NSFe, RetroTune.Decoder.SPC, RetroTune.Decoder.GBS,
  RetroTune.Decoder.VGM, RetroTune.Decoder.GYM, RetroTune.Decoder.PT3;

{$R *.fmx}

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FHistory := TBitmap.Create(TuneSpectrumBands, 128);
  ResetSpectrum;
  OpenDialog.Filter := TTuneDecoders.DialogFilter;
  TimerTick(nil);
  PlaybackTimer.Enabled := True;
  if (ParamCount > 0) and TFile.Exists(ParamStr(1)) then
    LoadTune(ParamStr(1));
end;

destructor TFormMain.Destroy;
begin
  if PlaybackTimer <> nil then
    PlaybackTimer.Enabled := False;
  FPlayer.Free;
  FHistory.Free;
  inherited;
end;

procedure TFormMain.LoadTune(const Path: string);
var
  Decoder: ITuneDecoder;
  Info: TTuneInfo;
  I: Integer;
begin
  try
    Decoder := TTuneDecoders.Open(Path);
    Info := Decoder.GetInfo;
    // Parse first, so an invalid file leaves the currently loaded tune intact.
    FreeAndNil(FPlayer);
    FPlayer := TTunePlayer.Create(Decoder);
    FInfo := Info;
    ResetSpectrum;
    LabelHighFrequency.Text := Format('%g кГц', [Min(20000.0, FInfo.SampleRate / 2.0) / 1000]);
    Caption := 'RetroTune - ' + ExtractFileName(Path);
    if FInfo.Title <> '' then
      LabelTitle.Text := FInfo.Title
    else
      LabelTitle.Text := TPath.GetFileNameWithoutExtension(Path);
    LabelArtist.Text := FInfo.Artist;
    LabelCopyright.Text := FInfo.CopyrightText;
    LabelDetails.Text := Format('%s / %s / %d Гц / %d канал(ов)',
      [FInfo.FormatName, FInfo.Details, FInfo.SampleRate, FInfo.Channels]);
    FUpdating := True;
    try
      ComboTracks.Items.Clear;
      for I := 1 to FInfo.TrackCount do
        if (I - 1 < Length(Info.TrackNames)) and (Info.TrackNames[I - 1] <> '') then
          ComboTracks.Items.Add(Format('%d. %s', [I, Info.TrackNames[I - 1]]))
        else
          ComboTracks.Items.Add(Format('Композиция %d', [I]));
      ComboTracks.ItemIndex := FInfo.DefaultTrack;
    finally
      FUpdating := False;
    end;
    FPlayer.SetVolume(Round(TrackBarVolume.Value));
    FPlayer.Play;
    TimerTick(nil);
  except
    on E: Exception do
      ShowMessage('Не удалось открыть файл: ' + E.Message);
  end;
end;

procedure TFormMain.OpenClick(Sender: TObject);
begin
  if OpenDialog.Execute then
    LoadTune(OpenDialog.FileName);
end;

procedure TFormMain.PlayClick(Sender: TObject);
begin
  if FPlayer = nil then
    Exit;
  if FPlayer.Status.State = TTunePlayerState.Playing then
    FPlayer.Pause
  else
    FPlayer.Play;
  TimerTick(nil);
end;

procedure TFormMain.StopClick(Sender: TObject);
begin
  if FPlayer <> nil then
    FPlayer.Stop;
  ResetSpectrum;
  TimerTick(nil);
end;

procedure TFormMain.PreviousClick(Sender: TObject);
begin
  if ComboTracks.ItemIndex > 0 then
    ComboTracks.ItemIndex := ComboTracks.ItemIndex - 1;
end;

procedure TFormMain.NextClick(Sender: TObject);
begin
  if ComboTracks.ItemIndex < ComboTracks.Items.Count - 1 then
    ComboTracks.ItemIndex := ComboTracks.ItemIndex + 1;
end;

procedure TFormMain.TrackChange(Sender: TObject);
begin
  if FUpdating or (FPlayer = nil) or (ComboTracks.ItemIndex < 0) then
    Exit;
  FPlayer.SelectTrack(ComboTracks.ItemIndex);
  ResetSpectrum;
  TimerTick(nil);
end;

procedure TFormMain.VolumeChange(Sender: TObject);
begin
  if csLoading in ComponentState then
    Exit;
  LabelVolume.Text := Format('Громкость: %d%%', [Round(TrackBarVolume.Value)]);
  if FPlayer <> nil then
    FPlayer.SetVolume(Round(TrackBarVolume.Value));
end;

function PlaybackTime(Seconds: Double): string;
begin
  var Value := Trunc(Max(0.0, Seconds));
  if Value >= 3600 then
    Result := Format('%d:%.2d:%.2d', [Value div 3600, Value div 60 mod 60, Value mod 60])
  else
    Result := Format('%.2d:%.2d', [Value div 60, Value mod 60]);
end;

procedure TFormMain.PositionChange(Sender: TObject);
begin
  if FUpdating or (csLoading in ComponentState) or (FPlayer = nil) then
    Exit;
  FPlayer.Seek(TrackBarPosition.Value);
  ResetSpectrum;
end;

procedure TFormMain.PositionTracking(Sender: TObject);
begin
  if FUpdating or (csLoading in ComponentState) then
    Exit;
  LabelElapsed.Text := PlaybackTime(TrackBarPosition.Value);
end;

procedure TFormMain.TimerTick(Sender: TObject);
const
  StateText: array[TTunePlayerState] of string =
    ('Остановлено', 'Воспроизведение', 'Пауза', 'Композиция завершена');
var
  State: TTunePlayerStatus;
  Seconds: Integer;
begin
  ComboTracks.Enabled := FPlayer <> nil;
  TrackBarPosition.Enabled := FPlayer <> nil;
  ButtonPlay.Enabled := FPlayer <> nil;
  ButtonStop.Enabled := FPlayer <> nil;
  ButtonPrevious.Enabled := (FPlayer <> nil) and (ComboTracks.ItemIndex > 0);
  ButtonNext.Enabled := (FPlayer <> nil) and (ComboTracks.ItemIndex < ComboTracks.Items.Count - 1);
  UpdateSpectrum;
  if FPlayer = nil then
  begin
    FUpdating := True;
    try
      TrackBarPosition.Value := 0;
    finally
      FUpdating := False;
    end;
    LabelElapsed.Text := '00:00';
    LabelDuration.Text := '--:--';
    Exit;
  end;
  State := FPlayer.Status;
  if not TrackBarPosition.IsTracking then
  begin
    FUpdating := True;
    try
      if State.DurationSeconds >= 0 then
        TrackBarPosition.Max := Max(0.001, State.DurationSeconds)
      else
        TrackBarPosition.Max := Min(86400.0, Max(300.0, Ceil((State.Seconds + 60) / 60) * 60.0));
      TrackBarPosition.Value := State.Seconds;
    finally
      FUpdating := False;
    end;
    LabelElapsed.Text := PlaybackTime(State.Seconds);
  end;
  if State.DurationSeconds >= 0 then
    LabelDuration.Text := PlaybackTime(State.DurationSeconds)
  else
    LabelDuration.Text := '--:--';
  if State.State = TTunePlayerState.Playing then
    ButtonPlay.Text := 'Пауза'
  else if State.State = TTunePlayerState.Paused then
    ButtonPlay.Text := 'Продолжить'
  else
    ButtonPlay.Text := 'Воспроизвести';
  Seconds := Trunc(State.Seconds);
  if State.Seeking then
    LabelStatus.Text := 'Перемотка…'
  else if State.Error <> '' then
    LabelStatus.Text := 'Ошибка: ' + State.Error
  else
    LabelStatus.Text := Format('%s · %d / %d · %.2d:%.2d',
      [StateText[State.State], State.Track + 1, FInfo.TrackCount, Seconds div 60, Seconds mod 60]);
end;

procedure TFormMain.ResetSpectrum;
begin
  FBands := Default(TTuneSpectrum);
  FillChar(FStereoBands, SizeOf(FStereoBands), 0);
  FStereoPCM := Default(TTuneStereoWindow);
  FStereoLevels := Default(TTuneStereoLevels);
  FPeaks := Default(TTuneSpectrum);
  FillChar(FPeakHold, SizeOf(FPeakHold), 0);
  if FHistory <> nil then
    FHistory.Clear($FF0E172A);
  SpectrumPaintBox.Repaint;
end;

procedure TFormMain.SpectrumChange(Sender: TObject);
begin
  if not (csLoading in ComponentState) then
  begin
    LabelLowFrequency.Visible := not (ComboSpectrum.ItemIndex in [9, 10]);
    LabelHighFrequency.Visible := LabelLowFrequency.Visible;
    if ComboSpectrum.ItemIndex in [7, 8] then
    begin
      AnalyzeSpectrum(FStereoPCM.Left, FInfo.SampleRate, FStereoBands[0]);
      AnalyzeSpectrum(FStereoPCM.Right, FInfo.SampleRate, FStereoBands[1]);
    end;
    SpectrumPaintBox.Repaint;
  end;
end;

procedure TFormMain.UpdateSpectrum;
var
  Samples: TTunePCMWindow;
  Target: TTuneSpectrum;
  StereoTarget: array[0..1] of TTuneSpectrum;
  Rate, I, X, Y: Integer;
  Value: Single;
  Pixels: TBitmapData;
  Color: TAlphaColor;
begin
  if FHistory = nil then
    Exit;
  if FPlayer = nil then
    Exit;
  if FPlayer.Status.State in [TTunePlayerState.Stopped, TTunePlayerState.Finished] then
  begin
    ResetSpectrum;
    Exit;
  end;
  if FPlayer.Status.State <> TTunePlayerState.Playing then
    Exit;
  FPlayer.GetStereoVisualization(FStereoPCM, Rate);
  for I := 0 to TuneFFTSize - 1 do
    Samples[I] := (FStereoPCM.Left[I] + FStereoPCM.Right[I]) * 0.5;
  AnalyzeStereo(FStereoPCM, FStereoLevels);
  if ComboSpectrum.ItemIndex in [7, 8] then
  begin
    AnalyzeSpectrum(FStereoPCM.Left, Rate, StereoTarget[0]);
    AnalyzeSpectrum(FStereoPCM.Right, Rate, StereoTarget[1]);
    for var Channel := 0 to 1 do
      for I := 0 to TuneSpectrumBands - 1 do
        FStereoBands[Channel][I] := FStereoBands[Channel][I] +
          (StereoTarget[Channel][I] - FStereoBands[Channel][I]) *
          IfThen(StereoTarget[Channel][I] > FStereoBands[Channel][I], 0.65, 0.18);
  end;
  AnalyzeSpectrum(Samples, Rate, Target);
  for I := 0 to TuneSpectrumBands - 1 do
  begin
    if Target[I] > FBands[I] then
      FBands[I] := FBands[I] + (Target[I] - FBands[I]) * 0.65
    else
      FBands[I] := FBands[I] + (Target[I] - FBands[I]) * 0.18;
    if FBands[I] >= FPeaks[I] then
    begin
      FPeaks[I] := FBands[I];
      FPeakHold[I] := 12;
    end
    else if FPeakHold[I] > 0 then
      Dec(FPeakHold[I])
    else
      FPeaks[I] := Max(FBands[I], FPeaks[I] - 0.015);
  end;
  if FHistory.Map(TMapAccess.ReadWrite, Pixels) then
  try
    for Y := FHistory.Height - 1 downto 1 do
      for X := 0 to TuneSpectrumBands - 1 do
        Pixels.SetPixel(X, Y, Pixels.GetPixel(X, Y - 1));
    for X := 0 to TuneSpectrumBands - 1 do
    begin
      Value := Target[X];
      if Value < 0.5 then
        Color := $FF000000 or (Round(14 + Value * 2 * 10) shl 16) or
          (Round(23 + Value * 2 * 99) shl 8) or Round(42 + Value * 2 * 168)
      else
        Color := $FF000000 or (Round(24 + (Value - 0.5) * 2 * 207) shl 16) or
          (Round(122 + (Value - 0.5) * 2 * 121) shl 8) or Round(210 + (Value - 0.5) * 2 * 45);
      Pixels.SetPixel(X, 0, Color);
    end;
  finally
    FHistory.Unmap(Pixels);
  end;
  SpectrumPaintBox.Repaint;
end;

procedure TFormMain.SpectrumPaint(Sender: TObject; Canvas: TCanvas);
var
  W, H, Step, X, Y, Level, CenterX, CenterY, Radius, Reach, Angle, Gain, Mid, Side: Single;
  I, Segment, Channel: Integer;
  Area, Curve: TPathData;
  Saved: TCanvasSaveState;

  function ChannelColor(Index: Integer): TAlphaColor;
  begin
    if Index = 0 then
      Result := $FF53ADFF
    else
      Result := $FF3CCEB0;
  end;

  function MeterLevel(Value: Single): Single;
  begin
    Result := EnsureRange((20 * Log10(Max(Value, 0.000001)) + 60) / 60, 0.0, 1.0);
  end;

  procedure Text(const Bounds: TRectF; const Caption: string; Color: TAlphaColor);
  begin
    Canvas.Fill.Color := Color;
    Canvas.Font.Size := 11;
    Canvas.FillText(Bounds, Caption, False, 1, [], TTextAlign.Leading, TTextAlign.Center);
  end;

begin
  W := SpectrumPaintBox.Width;
  H := SpectrumPaintBox.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  Saved := Canvas.SaveState;
  try
    if (ComboSpectrum.ItemIndex = 2) and (FHistory <> nil) then
    begin
      Canvas.DrawBitmap(FHistory, RectF(0, 0, FHistory.Width, FHistory.Height),
        RectF(0, 0, W, H), 1);
      Exit;
    end;
    Canvas.Stroke.Kind := TBrushKind.Solid;
    Canvas.Stroke.Color := $20909090;
    Canvas.Stroke.Thickness := 1;
    Canvas.Fill.Kind := TBrushKind.Solid;
    if ComboSpectrum.ItemIndex = 7 then
    begin
      Step := W / TuneSpectrumBands;
      for Channel := 0 to 1 do
      begin
        Canvas.Fill.Color := ChannelColor(Channel);
        for I := 0 to TuneSpectrumBands - 1 do
        begin
          X := I * Step;
          Level := FStereoBands[Channel][I] * Max(0.0, H / 2 - 14);
          Y := (Channel + 1) * H / 2;
          Canvas.FillRect(RectF(X + Step * 0.1, Y - Level,
              X + Step * 0.9, Y), 0, 0, AllCorners, 1);
        end;
        Text(RectF(4, Channel * H / 2, 90, Channel * H / 2 + 14),
          IfThen(Channel = 0, 'L · левый', 'R · правый'), ChannelColor(Channel));
      end;
      Canvas.Stroke.Color := $4088CDEE;
      Canvas.DrawLine(PointF(0, H / 2), PointF(W, H / 2), 1);
      Exit;
    end;
    if ComboSpectrum.ItemIndex = 8 then
    begin
      for I := 1 to 4 do
        Canvas.DrawLine(PointF(0, H * I / 4), PointF(W, H * I / 4), 1);
      Curve := TPathData.Create;
      try
        for Channel := 0 to 1 do
        begin
          Curve.Clear;
          for I := 0 to TuneSpectrumBands - 1 do
          begin
            X := I * W / (TuneSpectrumBands - 1);
            Y := H - FStereoBands[Channel][I] * Max(0.0, H - 18) - 2;
            if I = 0 then
              Curve.MoveTo(PointF(X, Y))
            else
              Curve.LineTo(PointF(X, Y));
          end;
          Canvas.Stroke.Color := ChannelColor(Channel);
          Canvas.Stroke.Thickness := 2;
          Canvas.DrawPath(Curve, 0.8);
        end;
      finally
        Curve.Free;
      end;
      Text(RectF(4, 0, 110, 16), 'L · левый', ChannelColor(0));
      Text(RectF(110, 0, 220, 16), 'R · правый', ChannelColor(1));
      Exit;
    end;
    if ComboSpectrum.ItemIndex = 9 then
    begin
      CenterX := W * 0.3;
      CenterY := H / 2;
      Radius := Min(W * 0.27, H * 0.43);
      Canvas.Stroke.Color := $4088CDEE;
      Canvas.DrawEllipse(RectF(CenterX - Radius, CenterY - Radius, CenterX + Radius, CenterY + Radius), 1);
      Canvas.DrawLine(PointF(CenterX - Radius, CenterY), PointF(CenterX + Radius, CenterY), 1);
      Canvas.DrawLine(PointF(CenterX, CenterY - Radius), PointF(CenterX, CenterY + Radius), 1);
      Gain := Max(FStereoLevels.Peak[0], FStereoLevels.Peak[1]);
      if Gain > 0.000001 then
        Gain := Radius / Gain
      else
        Gain := 0;
      Curve := TPathData.Create;
      try
        for I := 0 to TuneFFTSize - 1 do
        begin
          Mid := (FStereoPCM.Left[I] + FStereoPCM.Right[I]) * 0.5;
          Side := (FStereoPCM.Right[I] - FStereoPCM.Left[I]) * 0.5;
          X := CenterX + Side * Gain;
          Y := CenterY - Mid * Gain;
          if I = 0 then
            Curve.MoveTo(PointF(X, Y))
          else
            Curve.LineTo(PointF(X, Y));
        end;
        Canvas.Stroke.Color := $FF3CCEB0;
        Canvas.Stroke.Thickness := 1;
        Canvas.DrawPath(Curve, 0.65);
      finally
        Curve.Free;
      end;
      Text(RectF(W * 0.58, 0, W, H * 0.25), Format('Корреляция: %.2f', [FStereoLevels.Correlation]), $FFD6E5F5);
      X := W * 0.58;
      Reach := W * 0.39;
      Y := H * 0.4;
      Canvas.Stroke.Color := $6088CDEE;
      Canvas.DrawLine(PointF(X, Y), PointF(X + Reach, Y), 1);
      Level := X + (FStereoLevels.Correlation + 1) * 0.5 * Reach;
      Canvas.Fill.Color := $FF3CCEB0;
      Canvas.FillEllipse(RectF(Level - 3, Y - 3, Level + 3, Y + 3), 1);
      Text(RectF(X, H * 0.45, X + 20, H * 0.65), '-1', $FF88A5BD);
      Text(RectF(X + Reach * 0.5 - 3, H * 0.45, X + Reach * 0.5 + 15, H * 0.65), '0', $FF88A5BD);
      Text(RectF(X + Reach - 15, H * 0.45, X + Reach, H * 0.65), '+1', $FF88A5BD);
      Text(RectF(X, H * 0.68, W, H), 'Моно ↑  ·  противофаза ↔', $FF88A5BD);
      Exit;
    end;
    if ComboSpectrum.ItemIndex = 10 then
    begin
      for Channel := 0 to 1 do
      begin
        X := W * 0.05;
        Reach := W * 0.9;
        Y := Channel * H / 2 + H * 0.22;
        Canvas.Fill.Color := $201683D8;
        Canvas.FillRect(RectF(X, Y, X + Reach, Y + H * 0.16), 2, 2, AllCorners, 1);
        Canvas.Fill.Color := ChannelColor(Channel);
        Canvas.FillRect(RectF(X, Y, X + Reach * MeterLevel(FStereoLevels.RMS[Channel]), Y + H * 0.16), 2, 2, AllCorners, 1);
        Level := X + Reach * MeterLevel(FStereoLevels.Peak[Channel]);
        Canvas.Stroke.Color := $FFFFC45C;
        Canvas.Stroke.Thickness := 2;
        Canvas.DrawLine(PointF(Level, Y), PointF(Level, Y + H * 0.16), 1);
        Text(RectF(X, Channel * H / 2, W, Y), Format('%s   RMS %.1f dBFS   ·   пик %.1f dBFS',
            [IfThen(Channel = 0, 'L', 'R'), 20 * Log10(Max(FStereoLevels.RMS[Channel], 0.000001)),
              20 * Log10(Max(FStereoLevels.Peak[Channel], 0.000001))]), ChannelColor(Channel));
      end;
      Exit;
    end;
    if ComboSpectrum.ItemIndex = 5 then
    begin
      // Low frequencies start at twelve o'clock and advance clockwise.
      CenterX := W / 2;
      CenterY := H / 2;
      Radius := Min(W, H) * 0.18;
      Reach := Min(W, H) * 0.46 - Radius;
      Canvas.Stroke.Color := $301683D8;
      Canvas.DrawEllipse(RectF(CenterX - Radius, CenterY - Radius,
          CenterX + Radius, CenterY + Radius), 1);
      Canvas.Stroke.Thickness := Max(1.0, Min(4.0, Radius * 0.09));
      for I := 0 to TuneSpectrumBands - 1 do
      begin
        Angle := -Pi / 2 + I * 2 * Pi / TuneSpectrumBands;
        Level := FBands[I];
        Canvas.Stroke.Color := $FF1683D8;
        Canvas.DrawLine(PointF(CenterX + Cos(Angle) * Radius, CenterY + Sin(Angle) * Radius),
          PointF(CenterX + Cos(Angle) * (Radius + Max(1.0, Level * Reach)),
            CenterY + Sin(Angle) * (Radius + Max(1.0, Level * Reach))), 0.4 + Level * 0.6);
        Canvas.Fill.Color := $FF64D8EB;
        X := CenterX + Cos(Angle) * (Radius + FPeaks[I] * Reach);
        Y := CenterY + Sin(Angle) * (Radius + FPeaks[I] * Reach);
        if FPeaks[I] > 0 then
          Canvas.FillEllipse(RectF(X - 1, Y - 1, X + 1, Y + 1), 1);
      end;
      Exit;
    end;
    if ComboSpectrum.ItemIndex = 6 then
    begin
      // Two FFT bands per column; lit cells show the stronger of the pair.
      Step := W / (TuneSpectrumBands div 2);
      for I := 0 to TuneSpectrumBands div 2 - 1 do
      begin
        Level := Max(FBands[I * 2], FBands[I * 2 + 1]);
        X := I * Step;
        for Segment := 0 to 23 do
        begin
          Y := H - (Segment + 1) * H / 24;
          if (Segment + 1) / 24 > Level then
            Canvas.Fill.Color := $181683D8
          else if Segment >= 21 then
            Canvas.Fill.Color := $FFFF7085
          else if Segment >= 17 then
            Canvas.Fill.Color := $FFFFC45C
          else
            Canvas.Fill.Color := $FF3CCEB0;
          Canvas.FillRect(RectF(X + Step * 0.12, Y + H / 240,
              X + Step * 0.88, Y + H / 24 - H / 240), 0, 0, AllCorners, 1);
        end;
      end;
      Exit;
    end;
    for I := 1 to 4 do
      Canvas.DrawLine(PointF(0, H * I / 4), PointF(W, H * I / 4), 1);
    Step := W / TuneSpectrumBands;
    Canvas.Fill.Kind := TBrushKind.Solid;
    Canvas.Fill.Color := $FF1683D8;
    if ComboSpectrum.ItemIndex = 4 then
    begin
      Canvas.Stroke.Color := $6088CDEE;
      Canvas.DrawLine(PointF(0, H / 2), PointF(W, H / 2), 1);
      for I := 0 to TuneSpectrumBands - 1 do
      begin
        X := I * Step;
        Level := FBands[I] * Max(0.0, H / 2 - 2);
        Canvas.Fill.Color := $FF1683D8;
        Canvas.FillRect(RectF(X + Step * 0.1, H / 2 - Level,
            X + Step * 0.9, H / 2), 0, 0, AllCorners, 1);
        Canvas.Fill.Color := $FF3CCEB0;
        Canvas.FillRect(RectF(X + Step * 0.1, H / 2,
            X + Step * 0.9, H / 2 + Level), 0, 0, AllCorners, 0.7);
      end;
      Exit;
    end;
    if ComboSpectrum.ItemIndex <> 1 then
    begin
      for I := 0 to TuneSpectrumBands - 1 do
      begin
        X := I * Step;
        Y := H - Max(2.0, FBands[I] * (H - 4));
        Canvas.Fill.Color := $FF1683D8;
        Canvas.FillRect(RectF(X + Step * 0.1, Y, X + Step * 0.9, H), 2, 2, AllCorners, 1);
        if (ComboSpectrum.ItemIndex = 3) and (FPeaks[I] > 0) then
        begin
          Y := Max(0.0, H - FPeaks[I] * (H - 4) - 2);
          Canvas.Fill.Color := $FF64D8EB;
          Canvas.FillRect(RectF(X + Step * 0.1, Y, X + Step * 0.9, Y + 2), 0, 0, AllCorners, 1);
        end;
      end;
    end
    else
    begin
      Area := TPathData.Create;
      Curve := TPathData.Create;
      try
        Area.MoveTo(PointF(0, H));
        for I := 0 to TuneSpectrumBands - 1 do
        begin
          X := I * W / (TuneSpectrumBands - 1);
          Y := H - Max(2.0, FBands[I] * (H - 4));
          Area.LineTo(PointF(X, Y));
          if I = 0 then
            Curve.MoveTo(PointF(X, Y))
          else
            Curve.LineTo(PointF(X, Y));
        end;
        Area.LineTo(PointF(W, H));
        Area.ClosePath;
        Canvas.Fill.Color := $301683D8;
        Canvas.FillPath(Area, 1);
        Canvas.Stroke.Color := $FF1683D8;
        Canvas.Stroke.Thickness := 2;
        Canvas.DrawPath(Curve, 1);
      finally
        Curve.Free;
        Area.Free;
      end;
    end;
  finally
    Canvas.RestoreState(Saved);
  end;
end;

end.

