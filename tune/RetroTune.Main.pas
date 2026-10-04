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
  private
    FPlayer: TTunePlayer;
    FInfo: TTuneInfo;
    FUpdating: Boolean;
    FBands: TTuneSpectrum;
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
  System.IOUtils, System.Math, RetroTune.Decoder.NSF, RetroTune.Decoder.NSFe,
  RetroTune.Decoder.SPC, RetroTune.Decoder.GBS, RetroTune.Decoder.VGM,
  RetroTune.Decoder.GYM;

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

procedure TFormMain.TimerTick(Sender: TObject);
const
  StateText: array[TTunePlayerState] of string =
    ('Остановлено', 'Воспроизведение', 'Пауза', 'Композиция завершена');
var
  State: TTunePlayerStatus;
  Seconds: Integer;
begin
  ComboTracks.Enabled := FPlayer <> nil;
  ButtonPlay.Enabled := FPlayer <> nil;
  ButtonStop.Enabled := FPlayer <> nil;
  ButtonPrevious.Enabled := (FPlayer <> nil) and (ComboTracks.ItemIndex > 0);
  ButtonNext.Enabled := (FPlayer <> nil) and (ComboTracks.ItemIndex < ComboTracks.Items.Count - 1);
  UpdateSpectrum;
  if FPlayer = nil then
    Exit;
  State := FPlayer.Status;
  if State.State = TTunePlayerState.Playing then
    ButtonPlay.Text := 'Пауза'
  else if State.State = TTunePlayerState.Paused then
    ButtonPlay.Text := 'Продолжить'
  else
    ButtonPlay.Text := 'Воспроизвести';
  Seconds := Trunc(State.Seconds);
  if State.Error <> '' then
    LabelStatus.Text := 'Ошибка: ' + State.Error
  else
    LabelStatus.Text := Format('%s · %d / %d · %.2d:%.2d',
      [StateText[State.State], State.Track + 1, FInfo.TrackCount, Seconds div 60, Seconds mod 60]);
end;

procedure TFormMain.ResetSpectrum;
begin
  FBands := Default(TTuneSpectrum);
  if FHistory <> nil then
    FHistory.Clear($FF0E172A);
  SpectrumPaintBox.Repaint;
end;

procedure TFormMain.SpectrumChange(Sender: TObject);
begin
  if not (csLoading in ComponentState) then
    SpectrumPaintBox.Repaint;
end;

procedure TFormMain.UpdateSpectrum;
var
  Samples: TTunePCMWindow;
  Target: TTuneSpectrum;
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
  FPlayer.GetVisualization(Samples, Rate);
  AnalyzeSpectrum(Samples, Rate, Target);
  for I := 0 to TuneSpectrumBands - 1 do
  begin
    if Target[I] > FBands[I] then
      FBands[I] := FBands[I] + (Target[I] - FBands[I]) * 0.65
    else
      FBands[I] := FBands[I] + (Target[I] - FBands[I]) * 0.18;
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
  W, H, Step, X, Y: Single;
  I: Integer;
  Area, Curve: TPathData;
begin
  W := SpectrumPaintBox.Width;
  H := SpectrumPaintBox.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  if (ComboSpectrum.ItemIndex = 2) and (FHistory <> nil) then
  begin
    Canvas.DrawBitmap(FHistory, RectF(0, 0, FHistory.Width, FHistory.Height),
      RectF(0, 0, W, H), 1);
    Exit;
  end;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := $20909090;
  Canvas.Stroke.Thickness := 1;
  for I := 1 to 4 do
    Canvas.DrawLine(PointF(0, H * I / 4), PointF(W, H * I / 4), 1);
  Step := W / TuneSpectrumBands;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FF1683D8;
  if ComboSpectrum.ItemIndex <> 1 then
  begin
    for I := 0 to TuneSpectrumBands - 1 do
    begin
      X := I * Step;
      Y := H - Max(2.0, FBands[I] * (H - 4));
      Canvas.FillRect(RectF(X + 1, Y, X + Step - 2, H), 2, 2, AllCorners, 1);
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
end;

end.

