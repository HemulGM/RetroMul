unit RetroTune.Main;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Filter.Effects, FMX.ListBox, FMX.Controls.Presentation, RetroTune.Decoder,
  RetroTune.Player, RetroTune.Spectrum, RetroTune.Export.WAV, FMX.Layouts,
  FMX.Objects, RetroTune.InfoForm, RetroTune.FormatsForm, FMX.Menus,
  RetroTune.SoundFontCatalog;

type
  TFormMain = class(TForm)
    Lang: TLang;
    ButtonOpen: TButton;
    ButtonExport: TButton;
    ButtonCloseExport: TButton;
    SaveDialog: TSaveDialog;
    LayoutExport: TLayout;
    LabelExport: TLabel;
    ProgressExport: TProgressBar;
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
    ButtonInfo: TButton;
    ButtonFormats: TButton;
    procedure SpectrumChange(Sender: TObject);
    procedure SpectrumPaint(Sender: TObject; Canvas: TCanvas);
    procedure FormCreate(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure CloseExportClick(Sender: TObject);
    procedure InfoClick(Sender: TObject);
    procedure FormatsClick(Sender: TObject);
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
    FSoundFontButton: TButton;
    FSoundFontMenu: TPopupMenu;
    FStandardSoundFonts: TArray<TStandardSoundFont>;
    FPlayer: TTunePlayer;
    FExport: TTuneWavExport;
    FInfoWindow: TTuneInfoForm;
    FFormatsWindow: TTuneFormatsForm;
    FSourceData: TBytes;
    FSourcePath: string;
    FInfo: TTuneInfo;
    FUpdating: Boolean;
    FBands: TTuneSpectrum;
    FStereoBands: array[0..1] of TTuneSpectrum;
    FStereoPCM: TTuneStereoWindow;
    FStereoLevels: TTuneStereoLevels;
    FPeaks: TTuneSpectrum;
    FPeakHold: array[0..TuneSpectrumBands - 1] of Integer;
    FHistory: TBitmap;
    procedure SoundFontClick(Sender: TObject);
    procedure SoundFontChoice(Sender: TObject);
    procedure CustomSoundFontClick(Sender: TObject);
    procedure ApplySoundFont(const Path: string);
    procedure UpdateSoundFontMenu;
    procedure UpdateSpectrum;
    procedure ResetSpectrum;
    procedure LoadTune(const Path: string; UseSnapshot: Boolean = False);
    procedure UpdateExport;
  public
    destructor Destroy; override;
  end;

var
  FormMain: TFormMain;

function TuneLanguageForLocale(const LocaleID: string): string;

implementation

uses
  System.IOUtils, System.Math, System.StrUtils, FMX.DialogService.Sync,
  FMX.Platform, RetroTune.Decoder.TIA, RetroTune.Decoder.KSS,
  RetroTune.Decoder.HES, RetroTune.Decoder.AHX, RetroTune.Decoder.DSF,
  RetroTune.Decoder.TRDOS, RetroTune.Decoder.NSF, RetroTune.Decoder.NSFe,
  RetroTune.Decoder.SPC, RetroTune.Decoder.GBS, RetroTune.Decoder.VGM,
  RetroTune.Decoder.GYM, RetroTune.Decoder.OPLDumps, RetroTune.Decoder.XGM,
  RetroTune.Decoder.ProTracker, RetroTune.Decoder.PT3,
  RetroTune.Decoder.ZXTrackers, RetroTune.Decoder.AYDumps,
  RetroTune.Decoder.Atari, RetroTune.Decoder.TurboFM,
  RetroTune.Decoder.Containers, RetroTune.Decoder.Digital, RetroTune.Decoder.SAA,
  RetroTune.Decoder.WAV, RetroTune.Decoder.MIDI, System.IniFiles;

{$R *.fmx}

function PlaybackTime(Seconds: Double): string; forward;

function TuneLanguageForLocale(const LocaleID: string): string;
begin
  var ID := LowerCase(Trim(LocaleID));
  if (ID = 'ru') or ID.StartsWith('ru-') or ID.StartsWith('ru_') or
    ID.StartsWith('ru.') or ID.StartsWith('ru@') then
    Result := 'ru'
  else
    Result := 'en';
end;

procedure TFormMain.FormCreate(Sender: TObject);
var
  Locale: IFMXLocaleService;
  LanguageID: string;
begin
  LanguageID := 'en';
  if TPlatformServices.Current.SupportsPlatformService(IFMXLocaleService, Locale) then
    LanguageID := TuneLanguageForLocale(Locale.GetCurrentLangID);
  Lang.Lang := LanguageID;
  // Translate form text immediately, before the first paint or status update.
  for var I := 0 to ComponentCount - 1 do
  begin
    if (Components[I] is TTextControl) and TTextControl(Components[I]).AutoTranslate then
      TTextControl(Components[I]).Text := Translate(TTextControl(Components[I]).Text);
    if (Components[I] is TStyledControl) and TStyledControl(Components[I]).AutoTranslate then
      TStyledControl(Components[I]).Hint := Translate(TStyledControl(Components[I]).Hint);
  end;
  for var I := 0 to ComboSpectrum.Items.Count - 1 do
    ComboSpectrum.Items[I] := Translate(ComboSpectrum.Items[I]);
  LabelTitle.Text := Translate('Choose music');
  LabelArtist.Text := Translate('Open a file to start listening');
  LabelDetails.Text := Translate('Game music · RetroTune');
  OpenDialog.Title := Translate('Open music file');
  SaveDialog.Title := Translate('Export WAV');
  FHistory := TBitmap.Create(TuneSpectrumBands, 128);
  ResetSpectrum;
  FSoundFontButton := TButton.Create(Self);
  FSoundFontButton.Name := 'ButtonSoundFont';
  FSoundFontButton.Parent := LayoutFooter;
  FSoundFontButton.Align := TAlignLayout.Right;
  FSoundFontButton.Width := 120;
  FSoundFontButton.Margins.Left := 12;
  FSoundFontButton.Margins.Top := 6;
  FSoundFontButton.Margins.Bottom := 6;
  FSoundFontButton.Text := 'SoundFont';
  FSoundFontButton.Hint := 'MIDI SoundFont (.sf2)';
  FSoundFontButton.OnClick := SoundFontClick;
  FSoundFontMenu := TPopupMenu.Create(Self);
  FSoundFontMenu.Parent := Self;
  FSoundFontMenu.Name := 'MenuSoundFonts';
  FStandardSoundFonts := StandardSoundFonts(ExtractFilePath(ParamStr(0)));
  for var Index := 0 to High(FStandardSoundFonts) do
  begin
    var Item := TMenuItem.Create(Self);
    Item.Enabled := True;
    Item.Name := 'SoundFontPreset' + Index.ToString;
    Item.Text := FStandardSoundFonts[Index].Name;
    Item.AutoTranslate := False;
    Item.Tag := Index;
    Item.RadioItem := True;
    Item.AutoCheck := False;
    Item.OnClick := SoundFontChoice;
    FSoundFontMenu.AddObject(Item);
  end;
  var Separator := TMenuItem.Create(Self);
  Separator.Text := '-';
  FSoundFontMenu.AddObject(Separator);
  var CustomItem := TMenuItem.Create(Self);
  CustomItem.Name := 'SoundFontCustom';
  if Lang.Lang = 'ru' then
    CustomItem.Text := 'Свой SF2…'
  else
    CustomItem.Text := 'Custom SF2…';
  CustomItem.AutoTranslate := False;
  CustomItem.OnClick := CustomSoundFontClick;
  FSoundFontMenu.AddObject(CustomItem);
  var Settings := TIniFile.Create(TPath.Combine(TPath.GetHomePath, 'RetroTune.ini'));
  try
    var BankPath := Settings.ReadString('MIDI', 'SoundFont', '');
    var PresetID := Settings.ReadString('MIDI', 'SoundFontPreset', '');
    for var Font in FStandardSoundFonts do
      if Font.ID = PresetID then
      begin
        BankPath := Font.Path;
        Break;
      end;
    if BankPath <> '' then
    try
      SetMidiSoundFont(BankPath);
    except
      on E: Exception do
        LabelStatus.Text := E.Message;
    end;
  finally
    Settings.Free;
  end;
  UpdateSoundFontMenu;
  OpenDialog.Filter := TTuneDecoders.DialogFilter.Replace('Supported formats|',
    Translate('Supported formats') + '|');
  TimerTick(nil);
  PlaybackTimer.Enabled := True;
  if (ParamCount > 0) and TFile.Exists(ParamStr(1)) then
    LoadTune(ParamStr(1));
end;

destructor TFormMain.Destroy;
begin
  if PlaybackTimer <> nil then
    PlaybackTimer.Enabled := False;
  FExport.Free;
  FInfoWindow.Free;
  FFormatsWindow.Free;
  FPlayer.Free;
  FHistory.Free;
  inherited;
end;

procedure TFormMain.LoadTune(const Path: string; UseSnapshot: Boolean);
var
  Decoder: ITuneDecoder;
  Info: TTuneInfo;
  Data: TBytes;
  I: Integer;
  PreviousPlayback: TTunePlayerStatus;
  RestorePosition: Boolean;
begin
  try
    RestorePosition := UseSnapshot and (FPlayer <> nil);
    if UseSnapshot then
      Data := Copy(FSourceData)
    else
      Data := TTuneDecoders.ReadData(Path);
    Decoder := TTuneDecoders.OpenData(Data, ExtractFileExt(Path));
    Info := Decoder.GetInfo;
    // Parse first, so an invalid file leaves the currently loaded tune intact.
    if RestorePosition then
      PreviousPlayback := FPlayer.Status;
    FreeAndNil(FPlayer);
    FPlayer := TTunePlayer.Create(Decoder);
    FInfo := Info;
    FSourceData := Data;
    FSourcePath := ExpandFileName(Path);
    if FInfoWindow <> nil then
      FInfoWindow.SetInfo(FSourcePath, Length(FSourceData), FInfo);
    ResetSpectrum;
    LabelHighFrequency.Text := Format(Translate('%g kHz'), [Min(20000.0, FInfo.SampleRate / 2.0) / 1000]);
    Caption := 'RetroTune - ' + ExtractFileName(Path);
    if FInfo.Title <> '' then
      LabelTitle.Text := FInfo.Title
    else
      LabelTitle.Text := TPath.GetFileNameWithoutExtension(Path);
    LabelArtist.Text := FInfo.Artist;
    LabelCopyright.Text := FInfo.CopyrightText;
    LabelDetails.Text := Format(Translate('%s / %s / %d Hz / %d channel(s)'),
      [FInfo.FormatName, FInfo.Details, FInfo.SampleRate, FInfo.Channels]);
    FUpdating := True;
    try
      ComboTracks.Items.Clear;
      for I := 1 to FInfo.TrackCount do
        if (I - 1 < Length(Info.TrackNames)) and (Info.TrackNames[I - 1] <> '') then
          ComboTracks.Items.Add(Format('%d. %s', [I, Info.TrackNames[I - 1]]))
        else
          ComboTracks.Items.Add(Format(Translate('Track %d'), [I]));
      for I := 0 to ComboTracks.Items.Count - 1 do
        ComboTracks.ListItems[I].AutoTranslate := False;
      if RestorePosition then
        ComboTracks.ItemIndex := PreviousPlayback.Track
      else
        ComboTracks.ItemIndex := FInfo.DefaultTrack;
    finally
      FUpdating := False;
    end;
    FPlayer.SetVolume(Round(TrackBarVolume.Value));
    if RestorePosition then
      FPlayer.RestorePlayback(PreviousPlayback)
    else
      FPlayer.Play;
    TimerTick(nil);
  except
    on E: Exception do
      ShowMessage(Translate('Could not open the file: ') + Translate(E.Message));
  end;
end;

procedure TFormMain.UpdateSoundFontMenu;
begin
  var ActivePath := MidiSoundFontPath;
  var StandardSelected := False;
  for var Index := 0 to High(FStandardSoundFonts) do
  begin
    var Item := TMenuItem(FindComponent('SoundFontPreset' + Index.ToString));
    Item.Enabled := StandardSoundFontAvailable(FStandardSoundFonts[Index].Path);
    Item.IsChecked := SameFileName(ActivePath, FStandardSoundFonts[Index].Path) or
      ((ActivePath = '') and not StandardSelected and Item.Enabled);
    StandardSelected := StandardSelected or Item.IsChecked;
  end;
  TMenuItem(FindComponent('SoundFontCustom')).IsChecked := (ActivePath <> '') and not StandardSelected;
  FSoundFontButton.Hint := MidiSoundFontName;
end;

procedure TFormMain.SoundFontClick(Sender: TObject);
begin
  if FExport <> nil then
    Exit;
  UpdateSoundFontMenu;
  var Point := FSoundFontButton.LocalToScreen(PointF(0, FSoundFontButton.Height));
  FSoundFontMenu.Popup(Point.X, Point.Y);
end;

procedure TFormMain.ApplySoundFont(const Path: string);
begin
  if FExport <> nil then
    Exit;
  var PreviousCursor := Cursor;
  Cursor := crHourGlass;
  try
    SetMidiSoundFont(Path);
    UpdateSoundFontMenu;
    if SameText(FInfo.FormatName, 'MIDI') then
      LoadTune(FSourcePath, True);
    var Settings := TIniFile.Create(TPath.Combine(TPath.GetHomePath, 'RetroTune.ini'));
    try
      var PresetID := '';
      for var Font in FStandardSoundFonts do
        if SameText(MidiSoundFontPath, Font.Path) then
        begin
          PresetID := Font.ID;
          Break;
        end;
      Settings.WriteString('MIDI', 'SoundFont', MidiSoundFontPath);
      Settings.WriteString('MIDI', 'SoundFontPreset', PresetID);
    finally
      Settings.Free;
    end;
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
  Cursor := PreviousCursor;
end;

procedure TFormMain.SoundFontChoice(Sender: TObject);
begin
  var Index := TMenuItem(Sender).Tag;
  if (Index < 0) or (Index >= Length(FStandardSoundFonts)) then
    Exit;
  ApplySoundFont(FStandardSoundFonts[Index].Path);
end;

procedure TFormMain.CustomSoundFontClick(Sender: TObject);
begin
  if FExport <> nil then
    Exit;
  var Dialog := TOpenDialog.Create(nil);
  try
    Dialog.Filter := 'SoundFont2|*.sf2';
    if Dialog.Execute then
      ApplySoundFont(Dialog.FileName);
  finally
    Dialog.Free;
  end;
end;

procedure TFormMain.OpenClick(Sender: TObject);
begin
  try
    if OpenDialog.Execute then
      LoadTune(OpenDialog.FileName);
  except
    on E: Exception do
      ShowMessage(Translate(E.Message));
  end;
end;

procedure TFormMain.ExportClick(Sender: TObject);
var
  Track: Integer;
  Seconds: Double;
  Values: TArray<string>;
  Prompt, Name: string;
begin
  if FExport <> nil then
  begin
    FExport.Cancel;
    ButtonExport.Enabled := False;
    LabelExport.Text := Translate('Cancelling export…');
    Exit;
  end;
  if FPlayer = nil then
    Exit;
  try
    Track := FPlayer.Status.Track;
    Seconds := FPlayer.Status.DurationSeconds;
    if Seconds > 0 then
      Prompt := Translate('Maximum duration in seconds (default: the whole track):')
    else
    begin
      Seconds := 180;
      Prompt := Translate('Duration in seconds (length unknown; default: 180):');
    end;
    Values := [FloatToStr(Seconds)];
    if not TDialogServiceSync.InputQuery(Format(Translate('Export WAV · track %d'), [Track + 1]),
      [Prompt], Values) then
      Exit;
    if not TryStrToFloat(Values[0], Seconds) then
      if not TryStrToFloat(Values[0].Replace(',', '.'), Seconds, TFormatSettings.Invariant) then
        raise EArgumentException.Create(Translate('Enter a duration in seconds'));
    if IsNan(Seconds) or IsInfinite(Seconds) or (Seconds <= 0) or (Seconds > 86400) then
      raise EArgumentOutOfRangeException.Create(Translate('Duration must be greater than 0 and no more than 86400 seconds'));
    Name := TPath.GetFileNameWithoutExtension(FSourcePath);
    if FInfo.TrackCount > 1 then
      Name := Name + Format(' - %.2d', [Track + 1]);
    SaveDialog.FileName := Name + '.wav';
    if SaveDialog.InitialDir = '' then
      SaveDialog.InitialDir := ExtractFilePath(FSourcePath);
    if not SaveDialog.Execute then
      Exit;
    if not SameText(ExtractFileExt(SaveDialog.FileName), '.wav') then
      raise EArgumentException.Create(Translate('Specify a filename with the .wav extension'));
    if SameFileName(ExpandFileName(SaveDialog.FileName), FSourcePath) then
      raise EArgumentException.Create(Translate('Choose another filename to preserve the source file'));
    FExport := TTuneWavExport.Create(FSourceData, ExtractFileExt(FSourcePath),
      SaveDialog.FileName, Track, Seconds);
    LayoutExport.Visible := True;
    LabelExport.Hint := ExpandFileName(SaveDialog.FileName);
    ProgressExport.Value := 0;
    UpdateExport;
  except
    on E: Exception do
      ShowMessage(Translate('Could not export WAV: ') + Translate(E.Message));
  end;
end;

procedure TFormMain.InfoClick(Sender: TObject);
begin
  if FPlayer = nil then
    Exit;
  if FInfoWindow = nil then
  begin
    FInfoWindow := TTuneInfoForm.Create(Self);
    FInfoWindow.StyleBook := StyleBookWinUI3;
  end;
  FInfoWindow.SetInfo(FSourcePath, Length(FSourceData), FInfo);
  FInfoWindow.Show;
  FInfoWindow.BringToFront;
end;

procedure TFormMain.FormatsClick(Sender: TObject);
begin
  if FFormatsWindow = nil then
  begin
    FFormatsWindow := TTuneFormatsForm.Create(Self);
    FFormatsWindow.StyleBook := StyleBookWinUI3;
  end;
  FFormatsWindow.Show;
  FFormatsWindow.BringToFront;
end;

procedure TFormMain.CloseExportClick(Sender: TObject);
begin
  if FExport = nil then
    LayoutExport.Visible := False;
end;

procedure TFormMain.UpdateExport;
var
  State: TTuneExportStatus;
begin
  FSoundFontButton.Enabled := FExport = nil;
  ButtonOpen.Enabled := FExport = nil;
  ButtonCloseExport.Enabled := FExport = nil;
  ButtonExport.Enabled := (FPlayer <> nil) or (FExport <> nil);
  if FExport = nil then
  begin
    ButtonExport.Text := Translate('Export WAV…');
    Exit;
  end;
  State := FExport.Status;
  ButtonExport.Text := Translate('Cancel export');
  if State.TotalFrames > 0 then
    ProgressExport.Value := 100.0 * State.Frames / State.TotalFrames;
  if State.State = TTuneExportState.Rendering then
  begin
    LabelExport.Text := Format(Translate('Exporting WAV: %.0f%%'), [ProgressExport.Value]);
    Exit;
  end;
  FreeAndNil(FExport);
  ButtonCloseExport.Enabled := True;
  ButtonExport.Text := Translate('Export WAV…');
  ButtonExport.Enabled := FPlayer <> nil;
  ButtonOpen.Enabled := True;
  case State.State of
    TTuneExportState.Completed:
      begin
        ProgressExport.Value := 100;
        LabelExport.Text := Format(Translate('WAV saved: %s · %s'),
          [ExtractFileName(State.Path), PlaybackTime(State.Frames / Max(1, State.SampleRate))]);
      end;
    TTuneExportState.Cancelled:
      LabelExport.Text := Translate('WAV export cancelled');
    TTuneExportState.Failed:
      begin
        LabelExport.Text := Translate('WAV export failed');
        ShowMessage(Translate('Could not export WAV: ') + Translate(State.Error));
      end;
  end;
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
  LabelVolume.Text := Format(Translate('Volume: %d%%'), [Round(TrackBarVolume.Value)]);
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
    ('Stopped', 'Playing', 'Pause', 'Track ended');
var
  State: TTunePlayerStatus;
  Seconds: Integer;
begin
  UpdateExport;
  ComboTracks.Enabled := FPlayer <> nil;
  ButtonInfo.Enabled := FPlayer <> nil;
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
    ButtonPlay.Text := Translate('Pause')
  else if State.State = TTunePlayerState.Paused then
    ButtonPlay.Text := Translate('Resume')
  else
    ButtonPlay.Text := Translate('Play');
  Seconds := Trunc(State.Seconds);
  if State.Seeking then
    LabelStatus.Text := Translate('Seeking…')
  else if State.Error <> '' then
    LabelStatus.Text := Translate('Error: ') + Translate(State.Error)
  else
    LabelStatus.Text := Format('%s · %d / %d · %.2d:%.2d',
      [Translate(StateText[State.State]), State.Track + 1, FInfo.TrackCount, Seconds div 60, Seconds mod 60]);
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
          IfThen(Channel = 0, Translate('L · left'), Translate('R · right')), ChannelColor(Channel));
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
      Text(RectF(4, 0, 110, 16), Translate('L · left'), ChannelColor(0));
      Text(RectF(110, 0, 220, 16), Translate('R · right'), ChannelColor(1));
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
      Text(RectF(W * 0.58, 0, W, H * 0.25), Format(Translate('Correlation: %.2f'), [FStereoLevels.Correlation]), $FFD6E5F5);
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
      Text(RectF(X, H * 0.68, W, H), Translate('Mono ↑  ·  antiphase ↔'), $FF88A5BD);
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
        Text(RectF(X, Channel * H / 2, W, Y), Format(Translate('%s   RMS %.1f dBFS   ·   peak %.1f dBFS'),
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

