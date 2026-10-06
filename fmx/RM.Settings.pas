unit RM.Settings;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.Generics.Collections,
  System.Types, System.UITypes, FMX.Types, FMX.Controls, FMX.Layouts,
  FMX.StdCtrls, FMX.Text, FMX.Edit, FMX.EditBox, FMX.SpinBox, FMX.ListBox,
  FMX.Controls.Presentation, Core.Storage, Core.Emulation, FMXInput;

type
  TSettingsLocationPicker = reference to procedure(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback);

  TSettingsField = class
    Control: TControl;
    Row: TPanel;
    Section, Key: string;
    Values: TArray<string>;
  end;

  TSettingsDevice = class
    Control: TControl;
    Diagram: TControl;
    Capture, Clear: TButton;
    Caption: TLabel;
    Port: Integer;
    Device: string;
  end;

  TSettingsView = class(TPanel)
  private
    FStorage: IStorage;
    FPicker: TSettingsLocationPicker;
    FInput: TInputManager; // Shared with the frontend; ownership stays with the form.
    FDrafts: array[0..5] of TMemIniFile;
    FFields: TObjectList<TSettingsField>;
    FDevices: TObjectList<TSettingsDevice>;
    FNavigation: TListBox;
    FPagePicker: TComboBox;
    FBody, FContent, FHeader, FFooter: TLayout;
    FScroll: TVertScrollBox;
    FTitle, FStatus: TLabel;
    FApply, FBack, FCancelCapture: TButton;
    FPage, FCaptureAction: Integer;
    FHeight: Single;
    FBuilding, FRebuildPending, FArranging: Boolean;
    FVolumeValue: TLabel;
    FCaptureDeadline: UInt64;
    FCaptureButton: TButton;
    FDeviceIds: array[0..7] of string;
    FOnApply, FOnClose: TNotifyEvent;
    FFolderEdit: TEdit;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    function Row(const Caption, Description: string): TPanel;
    function Field(Control: TControl; const Section, Key: string): TSettingsField;
    function Combo(const Caption, Description, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
    function Check(const Caption, Description, Section, Key: string; Default: Boolean): TSwitch;
    function Number(const Caption, Description, Section, Key: string; Default, Max: Integer): TSpinBox;
    function EditText(const Caption, Description, Section, Key, Default: string): TEdit;
    procedure Heading(const Caption: string);
    procedure NavigationChange(Sender: TObject);
    procedure PagePickerChange(Sender: TObject);
    procedure SelectPage(Index: Integer);
    procedure PortChange(Sender: TObject);
    procedure CaptureClick(Sender: TObject);
    procedure ClearBindingClick(Sender: TObject);
    procedure CancelCaptureClick(Sender: TObject);
    procedure PathClick(Sender: TObject);
    function PathEdit(const Caption, Description, Section, Key, Default: string; Folder: Boolean): TEdit;
    procedure VolumeChange(Sender: TObject);
    procedure ContentResize(Sender: TObject);
    procedure ComboResize(Sender: TObject);
    procedure BuildDevice(Port: Integer; const Device: string);
    procedure VirtualDeviceChange(Sender: TObject);
    procedure CalloutClick(Sender: TObject);
    procedure SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
    procedure RefreshBindings;
    procedure ApplyClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure StorePage;
    procedure BuildPage(PreserveScroll: Boolean = False);
    procedure RequestRebuild;
    procedure BuildPort(Port: Integer; const Caption: string);
    procedure BuildBindings(Port: Integer; const Device: string);
    function AddBinding(const Caption: string; Action, Port: Integer): TButton;
    procedure DeviceChange(Sender: TObject);
    procedure RefreshDevicesClick(Sender: TObject);
    procedure RowResize(Sender: TObject);
    procedure BindingFooterResize(Sender: TObject);
  protected
    procedure Resize; override;
    procedure PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback); virtual;
  public
    constructor CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
    destructor Destroy; override;
    procedure Poll;
    procedure CancelCapture;
    property OnApply: TNotifyEvent read FOnApply write FOnApply;
    property LocationPicker: TSettingsLocationPicker read FPicker write FPicker;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
  end;

const
  SettingsCoreIds: array[1..5] of string = ('gb', 'gbc', 'nes', 'md', 'snes');
  SettingsPageNames: array[0..5] of string = ('Основные', 'Game Boy', 'Game Boy Color',
    'NES / Famicom', 'Mega Drive', 'Super Nintendo');

implementation

uses
  System.Math, System.IOUtils, System.TypInfo, RM.Input, GB.Palettes,
  FMX.OpenDialog, RM.Gamepad, NES.PowerPad, NES.SuborKeyboard,
  NES.FamicomKeyboard, NES.MiraclePiano, NES.Controller, NES.MiraclePianoDevice,
  FMX.BehaviorManager, FMX.Graphics, FMX.SpinBox.Style, FMX.Presentation.Style,
  FMX.Presentation.Factory;

type
  TSettingsTrackBar = class(TTrackBar)
  protected
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  end;

  TSettingsSpinBox = class(TSpinBox)
  protected
    function DefinePresentationName: string; override;
  end;

  TSettingsSpinBoxStyle = class(TStyledSpinBox)
  protected
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  end;

  TDeviceCallouts = class;

  TBindingLines = class(TControl)
  protected
    procedure Paint; override;
  end;

  TBindingCallout = record
    Button: Integer;
    Name: string;
    Left: Boolean;
    LabelControl: TLabel;
  end;

  // The original device remains interactive; this frame only annotates it.
  TDeviceCallouts = class(TControl)
  private
    FDevice: TControl;
    FItems: TArray<TBindingCallout>;
    FLines: TBindingLines;
    FInput: TInputManager;
    function ButtonBounds(Index: Integer): TRectF;
    procedure AddCallout(Button, Action: Integer; const Name, Caption: string; Left: Boolean; Click: TNotifyEvent);
  protected
    procedure Resize; override;
  public
    procedure Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
    procedure Refresh;
  end;

procedure TSettingsTrackBar.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // Leave the wheel unhandled so the containing scroll box receives it.
end;

function TSettingsSpinBox.DefinePresentationName: string;
begin
  Result := 'SettingsSpinBox-' + GetPresentationSuffix;
end;

procedure TSettingsSpinBoxStyle.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // TStyledEditBox increments even when Handled is true; bypass that implementation.
end;

function TDeviceCallouts.ButtonBounds(Index: Integer): TRectF;
begin
  if FDevice is TNesPowerPad then
    Result := TNesPowerPad(FDevice).ButtonBounds(FItems[Index].Button)
  else
    Result := TScreenGamepad(FDevice).ButtonBounds(TEmulatorButton(FItems[Index].Button));
end;

procedure TDeviceCallouts.AddCallout(Button, Action: Integer; const Name, Caption: string; Left: Boolean; Click: TNotifyEvent);
begin
  var Index := Length(FItems);
  SetLength(FItems, Index + 1);
  FItems[Index].Button := Button;
  FItems[Index].Name := Name;
  FItems[Index].Left := Left;
  var L := TLabel.Create(Self);
  FItems[Index].LabelControl := L;
  L.Parent := Self;
  L.Height := 28;
  L.HitTest := FInput <> nil;
  L.OnClick := Click;
  L.Tag := Action;
  L.TagString := Caption;
  L.StyledSettings := L.StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
  L.TextSettings.Font.Size := 12;
  L.TextSettings.WordWrap := False;
  L.TextSettings.Trimming := TTextTrimming.Character;
  if Left then
    L.TextSettings.HorzAlign := TTextAlign.Trailing
  else
    L.TextSettings.HorzAlign := TTextAlign.Leading;
end;

procedure TDeviceCallouts.Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
begin
  HitTest := False;
  FDevice := Device;
  FInput := Input;
  FDevice.Parent := Self;
  FDevice.Align := TAlignLayout.None;
  FLines := TBindingLines.Create(Self);
  FLines.Parent := Self;
  FLines.Align := TAlignLayout.Client;
  FLines.HitTest := False;
  if Device is TNesPowerPad then
    for var Button := 1 to 12 do
      AddCallout(Button, PowerPadAction + Button - 1, IntToStr(Button),
        'Площадка ' + IntToStr(Button), (Button - 1) mod 4 < 2, Click)
  else
    for var B in TScreenGamepad(Device).ButtonMask do
    begin
      var Left := B in [TEmulatorButton.Up, TEmulatorButton.Down,
          TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.Select,
          TEmulatorButton.Mode];
      if (Core = 'snes') and (B = TEmulatorButton.C) then
        Left := True;
      var Name := CoreButtonName(Core, B);
      AddCallout(Ord(B), PadAction(Port, B), Name, 'Кнопка ' + Name, Left, Click);
    end;
  Refresh;
  Resize;
end;

procedure TDeviceCallouts.Refresh;
begin
  for var Item in FItems do
  begin
    var L := Item.LabelControl;
    if L = nil then
      Continue;
    var Assignment := BindingCaption(FInput, L.Tag);
    L.Text := Item.Name + ' · ' + Assignment;
    if Width < 460 then
      L.Text := Assignment;
    L.Hint := L.TagString + ': ' + Assignment;
    L.ShowHint := True;
  end;
end;

procedure TDeviceCallouts.Resize;
begin
  inherited;
  if csDestroying in ComponentState then
    Exit;
  if (FDevice = nil) or (FLines = nil) then
    Exit;
  var Rail := Min(170, Max(40, Width * 0.18));
  var Aspect: Single := 0.46;
  if FDevice is TNesPowerPad then
    Aspect := 3.8 / 4.4;
  var PadWidth := Min(Min(400, Max(40, Height / Aspect)), Max(40, Width - 2 * (Rail + 12)));
  FDevice.SetBounds((Width - PadWidth) / 2, (Height - PadWidth * Aspect) / 2,
    PadWidth, PadWidth * Aspect);
  for var Side := 0 to 1 do
  begin
    var Buttons: TArray<Integer> := nil;
    for var B := 0 to High(FItems) do
      if FItems[B].Left = (Side = 0) then
      begin
        var N := Length(Buttons);
        SetLength(Buttons, N + 1);
        Buttons[N] := B;
      end;
    // Match vertical button order to the callouts to limit crossed leaders.
    for var i := 0 to High(Buttons) - 1 do
      for var J := i + 1 to High(Buttons) do
      begin
        var ReverseColumns := (FDevice is TNesPowerPad) and (Side = 1);
        var EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X < ButtonBounds(Buttons[i]).CenterPoint.X;
        if ReverseColumns then
          EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X > ButtonBounds(Buttons[i]).CenterPoint.X;
        if (ButtonBounds(Buttons[J]).CenterPoint.Y < ButtonBounds(Buttons[i]).CenterPoint.Y) or
          ((ButtonBounds(Buttons[J]).CenterPoint.Y = ButtonBounds(Buttons[i]).CenterPoint.Y) and
          EarlierColumn) then
        begin
          var B := Buttons[i];
          Buttons[i] := Buttons[J];
          Buttons[J] := B;
        end;
      end;
    var Step := Min(34, Height / Max(1, Length(Buttons)));
    for var i := 0 to High(Buttons) do
    begin
      var L := FItems[Buttons[i]].LabelControl;
      var X: Single := 0;
      if Side = 1 then
        X := Width - Rail;
      L.SetBounds(X, (Height - Step * Length(Buttons)) / 2 + i * Step + (Step - L.Height) / 2,
        Rail, L.Height);
    end;
  end;
  Refresh;
  FLines.Repaint;
end;

procedure TBindingLines.Paint;
begin
  inherited;
  var D := TDeviceCallouts(Parent);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := TAlphaColors.Gray;
  Canvas.Stroke.Thickness := 1;
  for var B := 0 to High(D.FItems) do
  begin
    var R := D.ButtonBounds(B);
    var L := D.FItems[B].LabelControl;
    var Start := R.CenterPoint + D.FDevice.Position.Point;
    var Finish := TPointF.Create(L.Position.X - 5, L.Position.Y + L.Height / 2);
    Start.X := R.Right + D.FDevice.Position.X;
    if D.FItems[B].Left then
    begin
      Start.X := R.Left + D.FDevice.Position.X;
      Finish.X := L.Position.X + L.Width + 5;
    end;
    if (D.FDevice is TNesPowerPad) and ((D.FItems[B].Button - 1) mod 4 in [1, 2]) then
    begin
      // Route inner columns through the gaps below each row, away from pad numbers.
      Start := TPointF.Create(R.CenterPoint.X + D.FDevice.Position.X, R.Bottom + D.FDevice.Position.Y);
      var ExitPoint := TPointF.Create(Start.X, Start.Y + 4);
      var RailX := D.FDevice.Position.X + D.FDevice.Width + 8;
      if D.FItems[B].Left then
        RailX := D.FDevice.Position.X - 8;
      var Outside := TPointF.Create(RailX, ExitPoint.Y);
      var Elbow := TPointF.Create(RailX, Finish.Y);
      Canvas.DrawLine(Start, ExitPoint, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(ExitPoint, Outside, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Outside, Elbow, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Elbow, Finish, AbsoluteOpacity * 0.8);
    end
    else
    begin
      var Elbow := TPointF.Create((Start.X + Finish.X) / 2, Finish.Y);
      Canvas.DrawLine(Start, Elbow, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Elbow, Finish, AbsoluteOpacity * 0.8);
    end;
    Canvas.Fill.Color := TAlphaColors.Gray;
    Canvas.FillEllipse(TRectF.Create(Start.X - 2, Start.Y - 2, Start.X + 2, Start.Y + 2), AbsoluteOpacity);
  end;
end;

constructor TSettingsView.CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
begin
  inherited Create(AOwner);
  StyleLookup := 'panelstyle';
  FStorage := Storage;
  FInput := Input;
  FFields := TObjectList<TSettingsField>.Create;
  FDevices := TObjectList<TSettingsDevice>.Create;
  var Alive := True;
  FAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  FInvalidate :=
    procedure
    begin
      Alive := False;
    end;
  FDrafts[0] := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  FDrafts[0].WriteString('General', 'Path', FStorage.RomFolder);
  for var i := 1 to 5 do
    FDrafts[i] := FStorage.ReadConfig(FStorage.ConfigFile(SettingsCoreIds[i]));
  FNavigation := TListBox.Create(Self);
  FNavigation.Parent := Self;
  FNavigation.Align := TAlignLayout.Left;
  FNavigation.Width := 204;
  FNavigation.Margins.Rect := TRectF.Create(12, 24, 12, 12);
  FNavigation.ShowScrollBars := False;
  FNavigation.ScrollAnimation := TBehaviorBoolean.True;
  FNavigation.ItemHeight := 44;
  for var Name in SettingsPageNames do
  begin
    var Item := TListBoxItem.Create(Self);
    Item.Parent := FNavigation;
    Item.Text := Name;
    Item.StyleLookup := 'listboxitemstyle';
  end;
  FNavigation.ItemIndex := 0;
  FNavigation.OnChange := NavigationChange;
  FBody := TLayout.Create(Self);
  FBody.Parent := Self;
  FBody.Align := TAlignLayout.Client;
  FBody.Padding.Rect := TRectF.Create(24, 16, 24, 16);
  FHeader := TLayout.Create(Self);
  FHeader.Parent := FBody;
  FHeader.Align := TAlignLayout.Top;
  FHeader.Height := 100;
  FTitle := TLabel.Create(Self);
  FTitle.Parent := FHeader;
  FTitle.Align := TAlignLayout.Top;
  FTitle.Height := 44;
  FTitle.StyledSettings := FTitle.StyledSettings - [TStyledSetting.Size];
  FTitle.TextSettings.Font.Size := 28;
  FPagePicker := TComboBox.Create(Self);
  FPagePicker.Parent := FHeader;
  FPagePicker.Align := TAlignLayout.Bottom;
  FPagePicker.Height := 36;
  FPagePicker.OnResize := ComboResize;
  ComboResize(FPagePicker);
  for var Name in SettingsPageNames do
    FPagePicker.Items.Add(Name);
  FPagePicker.ItemIndex := 0;
  FPagePicker.OnChange := PagePickerChange;
  FFooter := TLayout.Create(Self);
  FFooter.Parent := FBody;
  FFooter.Align := TAlignLayout.Bottom;
  FFooter.Height := 96;
  FStatus := TLabel.Create(Self);
  FStatus.Parent := FFooter;
  FStatus.Align := TAlignLayout.Top;
  FStatus.Height := 48;
  FStatus.TextSettings.WordWrap := True;
  FApply := TButton.Create(Self);
  FApply.Parent := FFooter;
  FApply.Position.Y := 56;
  FApply.Width := 132;
  FApply.Height := 32;
  FApply.Text := 'Применить';
  FApply.StyleLookup := 'buttonstyle_accent';
  FApply.OnClick := ApplyClick;
  FBack := TButton.Create(Self);
  FBack.Parent := FFooter;
  FBack.Position.Point := TPointF.Create(144, 56);
  FBack.Width := 132;
  FBack.Height := 32;
  FBack.Text := 'Закрыть';
  FBack.OnClick := BackClick;
  FCancelCapture := TButton.Create(Self);
  FCancelCapture.Parent := FFooter;
  FCancelCapture.Position.Point := TPointF.Create(288, 56);
  FCancelCapture.Width := 132;
  FCancelCapture.Height := 32;
  FCancelCapture.Text := 'Отмена ввода';
  FCancelCapture.OnClick := CancelCaptureClick;
  FCancelCapture.Visible := False;
  FScroll := TVertScrollBox.Create(Self);
  FScroll.Parent := FBody;
  FScroll.Align := TAlignLayout.Client;
  FScroll.ShowScrollBars := True;
  FScroll.ScrollAnimation := TBehaviorBoolean.True;
  FScroll.OnResize := ContentResize;
  BuildPage;
end;

destructor TSettingsView.Destroy;
begin
  FBuilding := True;
  if Assigned(FInvalidate) then
    FInvalidate();
  CancelCapture;
  FFields.Free;
  FDevices.Free;
  for var Ini in FDrafts do
    Ini.Free;
  inherited;
end;

procedure TSettingsView.Resize;
begin
  if FBuilding or (csDestroying in ComponentState) then
    Exit;
  inherited;
  if (FBody = nil) or FArranging then
    Exit;
  FArranging := True;
  try
    FNavigation.Visible := Width >= 900;
    FPagePicker.Visible := not FNavigation.Visible;
    if Width < 600 then
      FTitle.Text := 'Параметры'
    else
      FTitle.Text := 'Параметры · ' + SettingsPageNames[FPage];
    if FPagePicker.Visible then
      FHeader.Height := 100
    else
      FHeader.Height := 56;
    var Y: Single := 0;
    if FContent = nil then
      Exit;
    FContent.Width := Min(960, Max(0, FScroll.Width - 16));
    for var i := 0 to FContent.ChildrenCount - 1 do
      if FContent.Children[i] is TControl then
      begin
        var C := TControl(FContent.Children[i]);
        if C is TPanel then
          RowResize(C);
        C.Position.Y := Y;
        Y := Y + C.Height + 8;
      end;
    FContent.Height := Y;
    FCancelCapture.Position.X := Max(0, FFooter.Width - FCancelCapture.Width);
    FApply.Visible := FCaptureButton = nil;
    FBack.Visible := FCaptureButton = nil;
  finally
    FArranging := False;
  end;
end;

procedure TSettingsView.ContentResize(Sender: TObject);
begin
  Resize;
end;

procedure TSettingsView.ComboResize(Sender: TObject);
begin
  var C := TComboBox(Sender);
  C.DisableMouseWheel := True;
  C.ItemHeight := C.Height;
  C.ListBox.ScrollAnimation := TBehaviorBoolean.True;
end;

procedure TSettingsView.RowResize(Sender: TObject);
begin
  var P := TPanel(Sender);
  if P.Tag = 1 then
    Exit; // Device preview keeps its aspect ratio.
  var Narrow := P.Width < 600;
  P.Height := IfThen(Narrow, 160, 88);
  // Only arrange application editors; a styled panel also owns its skin controls.
  for var i := 0 to P.ChildrenCount - 1 do
    if (P.Children[i] is TControl) and (P.Children[i].Owner = FContent) then
    begin
      var C := TControl(P.Children[i]);
      if Narrow then
      begin
        C.Height := 32;
        C.Align := TAlignLayout.Bottom;
        C.Margins.Top := 8;
        C.Margins.Bottom := 0;
      end
      else
      begin
        C.Align := TAlignLayout.Right;
        if C is TSwitch then
          C.Width := 56
        else if C is TLayout then
          C.Width := 268
        else
          C.Width := 220;
        C.Margins.Top := 16;
        C.Margins.Bottom := 16;
      end;
    end;
end;

function TSettingsView.Row(const Caption, Description: string): TPanel;
begin
  Result := TPanel.Create(FContent);
  Result.Parent := FContent;
  Result.Align := TAlignLayout.Top;
  Result.Margins.Bottom := 8;
  Result.Position.Y := FHeight;
  Result.Height := 88;
  Result.Width := FScroll.Width - 16;
  Result.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  Result.StyleLookup := 'panelstyle';
  Result.OnResize := RowResize;
  FHeight := FHeight + Result.Height + 8;
  var Text := TLayout.Create(Result);
  Text.Parent := Result;
  Text.Align := TAlignLayout.Client;
  Text.Margins.Right := 16;
  var Title := TLabel.Create(Text);
  Title.Parent := Text;
  Title.Align := TAlignLayout.Top;
  Title.Height := 24;
  Title.Text := Caption;
  Result.TagObject := Title;
  var Detail := TLabel.Create(Text);
  Detail.Parent := Text;
  Detail.Align := TAlignLayout.Client;
  Detail.Text := Description;
  Detail.Opacity := 0.72;
  Detail.TextSettings.WordWrap := True;
end;

function TSettingsView.Field(Control: TControl; const Section, Key: string): TSettingsField;
begin
  Result := TSettingsField.Create;
  Result.Control := Control;
  Result.Row := TPanel(Control.Parent);
  Result.Section := Section;
  Result.Key := Key;
  FFields.Add(Result);
  Control.Align := TAlignLayout.Right;
  Control.Width := 220;
  Control.Height := 32;
  Control.Margins.Top := 16;
  Control.Margins.Bottom := 16;
end;

function TSettingsView.Combo(const Caption, Description, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
begin
  Result := TComboBox.Create(FContent);
  Result.Parent := Row(Caption, Description);
  var F := Field(Result, Section, Key);
  Result.OnResize := ComboResize;
  ComboResize(Result);
  SetLength(F.Values, Length(Values));
  var Current := FDrafts[FPage].ReadString(Section, Key, Default);
  Result.ItemIndex := -1;
  for var i := 0 to High(Labels) do
  begin
    Result.Items.Add(Labels[i]);
    F.Values[i] := Values[i];
    if SameText(Current, Values[i]) then
      Result.ItemIndex := i;
  end;
  if Result.ItemIndex < 0 then
    Result.ItemIndex := 0;
end;

function TSettingsView.Check(const Caption, Description, Section, Key: string; Default: Boolean): TSwitch;
begin
  Result := TSwitch.Create(FContent);
  Result.Parent := Row(Caption, Description);
  Field(Result, Section, Key);
  Result.Width := 56;
  Result.IsChecked := FDrafts[FPage].ReadBool(Section, Key, Default);
end;

function TSettingsView.Number(const Caption, Description, Section, Key: string; Default, Max: Integer): TSpinBox;
begin
  Result := TSettingsSpinBox.Create(FContent);
  Result.Parent := Row(Caption, Description);
  Field(Result, Section, Key);
  Result.Min := 0;
  Result.Max := Max;
  Result.ValueType := TNumValueType.Integer;
  Result.Value := EnsureRange(FDrafts[FPage].ReadInteger(Section, Key, Default), 0, Max);
end;

function TSettingsView.EditText(const Caption, Description, Section, Key, Default: string): TEdit;
begin
  Result := TEdit.Create(FContent);
  Result.Parent := Row(Caption, Description);
  Field(Result, Section, Key);
  Result.Text := FDrafts[FPage].ReadString(Section, Key, Default);
end;

function TSettingsView.PathEdit(const Caption, Description, Section, Key, Default: string; Folder: Boolean): TEdit;
begin
  Result := EditText(Caption, Description, Section, Key, Default);
  {$IFDEF ANDROID}          Result.ReadOnly := True;{$ENDIF}
  var Browse := TEditButton.Create(Result);
  Browse.Parent := Result;
  Browse.Text := '…';
  Browse.Width := 32;
  Browse.Hint := 'Выбрать файл';
  if Folder then
    Browse.Hint := 'Выбрать папку';
  Browse.Tag := Ord(Folder);
  Browse.TagObject := Result;
  Browse.OnClick := PathClick;
end;

procedure TSettingsView.VolumeChange(Sender: TObject);
begin
  if FVolumeValue <> nil then
    FVolumeValue.Text := IntToStr(Round(TTrackBar(Sender).Value)) + '%';
end;

procedure TSettingsView.Heading(const Caption: string);
begin
  var L := TLabel.Create(FContent);
  L.Parent := FContent;
  L.Align := TAlignLayout.Top;
  L.Margins.Bottom := 8;
  L.Position.Y := FHeight;
  L.Height := 40;
  L.Text := Caption;
  L.StyledSettings := L.StyledSettings - [TStyledSetting.Size];
  L.TextSettings.Font.Size := 20;
  FHeight := FHeight + 48;
end;

procedure TSettingsView.StorePage;
begin
  for var F in FFields do
  begin
    if F.Control is TComboBox then
    begin
      var Index := TComboBox(F.Control).ItemIndex;
      if (Index >= 0) and (Index < Length(F.Values)) then
        FDrafts[FPage].WriteString(F.Section, F.Key, F.Values[Index]);
    end
    else if F.Control is TSwitch then
      FDrafts[FPage].WriteBool(F.Section, F.Key, TSwitch(F.Control).IsChecked)
    else if F.Control is TSpinBox then
      FDrafts[FPage].WriteInteger(F.Section, F.Key, Round(TSpinBox(F.Control).Value))
    else if F.Control is TTrackBar then
      FDrafts[FPage].WriteFloat(F.Section, F.Key, TTrackBar(F.Control).Value / 100)
    else if F.Control is TEdit then
      FDrafts[FPage].WriteString(F.Section, F.Key, TEdit(F.Control).Text.Trim);
  end;
  if (FPage > 0) and (FInput <> nil) then
    SaveInputBindings(FInput, FDrafts[FPage]);
end;

procedure TSettingsView.BuildPage(PreserveScroll: Boolean);
begin
  var Position := TPointF.Zero;
  if PreserveScroll then
    Position := FScroll.ViewportPosition;
  FScroll.BeginUpdate;
  FBuilding := True;
  try
    CancelCapture;
    FFolderEdit := nil;
    FVolumeValue := nil;
    FDevices.Clear;
    FFields.Clear;
    FreeAndNil(FContent);
    FContent := TLayout.Create(Self);
    FContent.Parent := FScroll;
    FContent.Width := Min(960, Max(0, FScroll.Width - 16));
    FHeight := 0;
    FTitle.Text := 'Параметры · ' + SettingsPageNames[FPage];
    FStatus.Text := 'Изменения сохраняются кнопкой «Применить».';
    FScroll.ViewportPosition := TPointF.Zero;
    if FPage = 0 then
    begin
      Heading('Библиотека игр');
      FFolderEdit := PathEdit('Папка с ROM', 'Корневая папка с подпапками gb, gbc, nes, megadrive и snes.',
        'General', 'Path', FStorage.RomFolder, True);
      Heading('Виртуальные контролы');
      Number('Отступ снизу', 'Расстояние от виртуальных кнопок до нижнего края экрана. Безопасная область учитывается автоматически.',
        'General', 'ControlBottomInset', 100, 400);
    end
    else
    begin
      if FInput <> nil then
        LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
      Heading('Звук и изображение');
      Check('Звук', 'Воспроизведение аудио этого ядра.', 'Audio', 'Enabled', True);
      var Volume := TSettingsTrackBar.Create(FContent);
      Volume.Parent := Row('Громкость', 'Уровень звука для этого ядра.');
      Field(Volume, 'Audio', 'Volume');
      var VolumeEditor := TLayout.Create(FContent);
      VolumeEditor.Parent := Volume.Parent;
      VolumeEditor.Align := TAlignLayout.Right;
      VolumeEditor.Width := 268;
      VolumeEditor.Margins.Top := 16;
      VolumeEditor.Margins.Bottom := 16;
      Volume.Parent := VolumeEditor;
      Volume.Align := TAlignLayout.Client;
      Volume.Margins.Rect := TRectF.Empty;
      FVolumeValue := TLabel.Create(VolumeEditor);
      FVolumeValue.Parent := VolumeEditor;
      FVolumeValue.Align := TAlignLayout.Right;
      FVolumeValue.Width := 52;
      FVolumeValue.Margins.Left := 8;
      FVolumeValue.TextSettings.HorzAlign := TTextAlign.Trailing;
      Volume.Min := 0;
      Volume.Max := 100;
      Volume.Value := EnsureRange(FDrafts[FPage].ReadFloat('Audio', 'Volume', 0.5), 0, 1) * 100;
      Volume.OnChange := VolumeChange;
      VolumeChange(Volume);
      Combo('Масштабирование изображения', 'Ближайший пиксель сохраняет резкость; сглаживание смягчает изображение.',
        'Video', 'Filter', ['Ближайший пиксель', 'Сглаживание'], ['nearest', 'linear'], 'nearest');
      case FPage of
        1:
          begin
            var Labels, Values: TArray<string>;
            SetLength(Labels, SCREEN_PALETTE_COUNT);
            SetLength(Values, SCREEN_PALETTE_COUNT);
            for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
            begin
              Labels[i] := ScreenPalettes[i].Name;
              Values[i] := IntToStr(i);
            end;
            Combo('Палитра Game Boy', 'Цвета монохромного экрана.', 'Video', 'Palette', Labels, Values, '0');
          end;
        2:
          Check('Цвета LCD', 'Приблизительная цветопередача экрана Game Boy Color.', 'Video', 'ColorCorrection', False);
        3:
          begin
            Combo('Регион NES', 'Частота кадров и тайминги. Автоматически — из данных ROM.', 'Video', 'Region',
              ['Автоматически', 'NTSC', 'PAL'], ['Auto', 'NTSC', 'PAL'], 'Auto');
            var FourScore := Check('Four Score', 'Подключает дополнительные геймпады 3 и 4. Несовместим с Zapper, Power Pad и Miracle Piano.',
              'Input', 'FourScore', False);
            FourScore.OnSwitch := PortChange;
          end;
        4:
          Heading('Контроллеры Mega Drive · 3 или 6 кнопок');
        5:
          begin
            Check('Обрезать overscan', 'Для режима 239 строк показывать центральные 224 строки; также для удвоенной высоты.',
              'Video', 'CropOverscan', False);
            var Multitap2 := Check('Multitap · порт 2', 'Подключает геймпады игроков 2–5. Игра должна поддерживать Multitap.',
              'Input', 'Multitap2', False);
            Multitap2.OnSwitch := PortChange;
            var Multitap1 := Check('Multitap · порт 1', 'Подключает геймпады игроков 1, 6, 7 и 8. Используется играми с поддержкой двух Multitap.',
              'Input', 'Multitap1', False);
            Multitap1.OnSwitch := PortChange;
          end;
      end;
      if FInput <> nil then
      begin
        var Refresh := TButton.Create(FContent);
        Refresh.Parent := FContent;
        Refresh.Align := TAlignLayout.Top;
        Refresh.Position.Y := FHeight;
        Refresh.Height := 32;
        Refresh.Margins.Bottom := 8;
        Refresh.Text := 'Обновить устройства ввода';
        Refresh.OnClick := RefreshDevicesClick;
        FHeight := FHeight + 40;
      end;
      if FPage <= 2 then
        BuildPort(0, 'Встроенный контроллер')
      else
      begin
        BuildPort(0, 'Порт 1');
        BuildPort(1, 'Порт 2');
        if (FPage = 3) and FDrafts[FPage].ReadBool('Input', 'FourScore', False) then
        begin
          BuildPort(2, 'Four Score · игрок 3');
          BuildPort(3, 'Four Score · игрок 4');
        end;
        if FPage = 5 then
        begin
          if FDrafts[FPage].ReadBool('Input', 'Multitap2', False) then
            for var Port := 2 to 4 do
              BuildPort(Port, 'Multitap · порт 2 · игрок ' + IntToStr(Port + 1));
          if FDrafts[FPage].ReadBool('Input', 'Multitap1', False) then
            for var Port := 5 to 7 do
              BuildPort(Port, 'Multitap · порт 1 · игрок ' + IntToStr(Port + 1));
        end;
      end;
      if FPage = 3 then
      begin
        Heading('Порт расширения Famicom');
        var Expansion := Combo('Подключённое устройство', 'Автоматически — по данным ROM. Клавиатура Famicom также подключает кассетный интерфейс.',
          'Ports', 'Expansion', ['Автоматически', 'Ничего', 'Клавиатура Subor', 'Клавиатура Famicom', 'Data Recorder'],
          ['auto', 'none', 'subor', 'famicom', 'recorder'], 'auto');
        Expansion.OnChange := PortChange;
        var Device := FDrafts[FPage].ReadString('Ports', 'Expansion', 'auto');
        if (Device = 'subor') or (Device = 'famicom') then
        begin
          Check('Физическая клавиатура', 'Стандартная раскладка устройства; экранная клавиатура доступна во время игры.',
            'Ports', 'KeyboardEnabled', True);
          BuildBindings(4, Device);
        end;
        if (Device = 'recorder') or (Device = 'famicom') then
          PathEdit('Начальная кассета', 'Полный путь к файлу .tape. Пустое поле использует кассету текущей игры.',
            'Ports', 'TapeFile', '', False);
      end;
      FStatus.Text := 'Назначения ввода действуют сразу. Параметры ядра и состав портов — при следующем открытии ROM.';
    end;
    FContent.Height := FHeight;
  finally
    FBuilding := False;
    FScroll.EndUpdate;
    Resize;
    FScroll.RealignContent;
    FScroll.ViewportPosition := TPointF.Create(0,
      EnsureRange(Position.Y, 0, Max(0, FScroll.ContentBounds.Height - FScroll.ClientHeight)));
  end;
end;

procedure TSettingsView.BuildPort(Port: Integer; const Caption: string);
begin
  Heading(Caption);
  var Key := 'Port' + IntToStr(Port + 1);
  var Device := FDrafts[FPage].ReadString('Ports', Key, 'auto');
  var C: TComboBox;
  if FPage <= 2 then
    C := Combo('Контроллер', 'Управление встроенными кнопками консоли.', 'Ports', Key,
      ['Геймпад', 'Ничего'], ['pad', 'none'], 'pad')
  else if FPage = 4 then
    C := Combo('Подключённое устройство', 'Протокол контроллера на этом порту.', 'Ports', Key,
      ['Геймпад · 6 кнопок', 'Геймпад · 3 кнопки', 'Ничего'], ['pad6', 'pad3', 'none'], 'pad6')
  else if (FPage = 3) and (Port = 0) then
    C := Combo('Подключённое устройство', 'Автоматически сохраняет выбор устройства из ROM.', 'Ports', Key,
      ['Автоматически', 'Геймпад', 'Miracle Piano', 'Ничего'], ['auto', 'pad', 'piano', 'none'], 'auto')
  else if (FPage = 3) and (Port = 1) then
    C := Combo('Подключённое устройство', 'Zapper и Power Pad занимают второй порт.', 'Ports', Key,
      ['Автоматически', 'Геймпад', 'Zapper', 'Power Pad', 'Ничего'],
      ['auto', 'pad', 'zapper', 'powerpad', 'none'], 'auto')
  else
    C := Combo('Подключённое устройство', 'Контроллер на этом порту.', 'Ports', Key,
      ['Геймпад', 'Ничего'], ['pad', 'none'], 'pad');
  // Normalize absent legacy values to the device displayed by the selector.
  for var F in FFields do
    if F.Control = C then
      Device := F.Values[C.ItemIndex];
  C.OnChange := PortChange;
  BuildBindings(Port, Device);
end;

procedure TSettingsView.BuildBindings(Port: Integer; const Device: string);
begin
  if Device = 'none' then
    Exit;
  var Labels, Values: TArray<string>;
  var Devices: TArray<TInputDevice>;
  if FInput <> nil then
    Devices := FInput.Devices;
  SetLength(Labels, Length(Devices) + 1);
  SetLength(Values, Length(Labels));
  Labels[0] := 'Все устройства';
  Values[0] := '';
  for var i := 0 to High(Devices) do
  begin
    Labels[i + 1] := Devices[i].Name;
    Values[i + 1] := Devices[i].Id;
  end;
  var SourceKey := 'Source' + IntToStr(Port + 1);
  if (FPage = 3) and (Port = 4) then
    SourceKey := 'SourceExpansion';
  var SavedId := FDrafts[FPage].ReadString('Ports', SourceKey, '');
  var Found := SavedId = '';
  for var Id in Values do
    if Id = SavedId then
      Found := True;
  if not Found then
  begin
    var N := Length(Labels);
    SetLength(Labels, N + 1);
    SetLength(Values, N + 1);
    Labels[N] := 'Отключённое устройство';
    Values[N] := SavedId;
  end;
  var Source := Combo('Источник ввода', 'Выберите устройство, затем назначьте его кнопки, оси или D-pad.',
    'Ports', SourceKey, Labels, Values, '');
  FDeviceIds[Port] := SavedId;
  Source.Tag := Port;
  Source.OnChange := DeviceChange;
  Source.Enabled := FInput <> nil;
  if (Device = 'piano') then
  begin
    Check('Физическая клавиатура', 'Ноты Z–M и Q–P; пробел — педаль. Экранное пианино также доступно.',
      'Ports', 'KeyboardEnabled', True);
  end;
  if Device = 'zapper' then
    AddBinding('Спуск Zapper', ZapperTriggerAction, Port)
  else
    BuildDevice(Port, Device);
end;

function TSettingsView.AddBinding(const Caption: string; Action, Port: Integer): TButton;
begin
  var P := Row(Caption, 'Нажмите «Назначить», затем кнопку или направление устройства.');
  var Editors := TLayout.Create(FContent);
  Editors.Parent := P;
  Editors.Align := TAlignLayout.Right;
  Editors.Width := 268;
  Editors.Height := 32;
  Editors.Margins.Top := 16;
  Editors.Margins.Bottom := 16;
  var B := TButton.Create(Editors);
  B.Parent := Editors;
  B.Align := TAlignLayout.Client;
  B.Text := 'Назначить · ' + BindingCaption(FInput, Action);
  B.Tag := Action;
  B.TagString := IntToStr(Port);
  B.TagObject := P.TagObject;
  B.OnClick := CaptureClick;
  B.Enabled := FInput <> nil;
  var Clear := TButton.Create(Editors);
  Clear.Parent := Editors;
  Clear.Align := TAlignLayout.Right;
  Clear.Width := 36;
  Clear.Margins.Left := 8;
  Clear.Text := '×';
  Clear.Hint := 'Удалить назначение';
  Clear.Tag := Action;
  Clear.OnClick := ClearBindingClick;
  Clear.Enabled := FInput <> nil;
  Result := B;
end;

procedure TSettingsView.BuildDevice(Port: Integer; const Device: string);
begin
  var D := TSettingsDevice.Create;
  FDevices.Add(D);
  D.Port := Port;
  D.Device := Device;
  var P := Row('Назначение кнопок', 'Выберите кнопку на устройстве, затем нажмите клавишу или кнопку контроллера.');
  P.Tag := 1;
  P.Height := 340;
  var Text := TLayout(P.Children[0]);
  Text.Align := TAlignLayout.Top;
  Text.Height := 60;
  if Device = 'powerpad' then
  begin
    var Pad := TNesPowerPad.Create(P);
    Pad.OnChange := VirtualDeviceChange;
    D.Control := Pad;
    var Diagram := TDeviceCallouts.Create(P);
    Diagram.Configure(Pad, FInput, 'nes', Port, CalloutClick);
    D.Diagram := Diagram;
    P.Height := 448;
  end
  else if Device = 'subor' then
  begin
    var Keyboard := TNesSuborKeyboard.Create(P);
    Keyboard.OnChange := VirtualDeviceChange;
    D.Control := Keyboard;
  end
  else if Device = 'famicom' then
  begin
    var Keyboard := TNesFamicomKeyboard.Create(P);
    Keyboard.OnChange := VirtualDeviceChange;
    D.Control := Keyboard;
  end
  else if Device = 'piano' then
  begin
    var Piano := TNesMiraclePiano.Create(P);
    Piano.OnChange := VirtualDeviceChange;
    D.Control := Piano;
  end
  else
  begin
    var Pad := TScreenGamepad.Create(P);
    case FPage of
      1:
        Pad.Layout := TScreenGamepadLayout.GameBoy;
      2:
        Pad.Layout := TScreenGamepadLayout.GameBoyColor;
      3:
        Pad.Layout := TScreenGamepadLayout.Nes;
      4:
        Pad.Layout := TScreenGamepadLayout.Sega;
      5:
        Pad.Layout := TScreenGamepadLayout.Snes;
    end;
    Pad.ButtonMask := CoreButtons(SettingsCoreIds[FPage], Device);
    Pad.OnChange := VirtualDeviceChange;
    D.Control := Pad;
    var Diagram := TDeviceCallouts.Create(P);
    Diagram.Configure(Pad, FInput, SettingsCoreIds[FPage], Port, CalloutClick);
    D.Diagram := Diagram;
    if FPage in [4, 5] then
      P.Height := 396
    else
      P.Height := 348;
  end;
  var Preview := D.Control;
  if D.Diagram <> nil then
    Preview := D.Diagram;
  Preview.Parent := P;
  Preview.Align := TAlignLayout.Client;
  Preview.Margins.Top := 8;
  Preview.Margins.Bottom := 8;
  D.Control.Tag := Port;
  // Keep the editor inside this card. No button is selected until the user clicks.
  var Footer := TLayout.Create(P);
  Footer.Parent := P;
  Footer.Align := TAlignLayout.Bottom;
  Footer.Height := 60;
  D.Caption := TLabel.Create(Footer);
  D.Caption.Parent := Footer;
  D.Caption.Align := TAlignLayout.Top;
  D.Caption.Height := 24;
  D.Caption.Text := '';
  var Editors := TLayout.Create(Footer);
  Editors.Parent := Footer;
  Editors.Align := TAlignLayout.Bottom;
  Editors.Height := 32;
  D.Capture := TButton.Create(Editors);
  D.Capture.Parent := Editors;
  D.Capture.Align := TAlignLayout.Client;
  D.Capture.Width := 220;
  D.Capture.Text := 'Назначить';
  D.Capture.Tag := -1;
  D.Capture.TagString := IntToStr(Port);
  D.Capture.TagObject := D.Caption;
  D.Capture.OnClick := CaptureClick;
  D.Capture.Enabled := FInput <> nil;
  D.Capture.Visible := False;
  D.Clear := TButton.Create(Editors);
  D.Clear.Parent := Editors;
  D.Clear.Align := TAlignLayout.Right;
  D.Clear.Width := 36;
  D.Clear.Margins.Left := 8;
  D.Clear.Text := '×';
  D.Clear.Hint := 'Удалить назначение';
  D.Clear.Tag := -1;
  D.Clear.OnClick := ClearBindingClick;
  D.Clear.Enabled := FInput <> nil;
  D.Clear.Visible := False;
  Footer.OnResize := BindingFooterResize;
  BindingFooterResize(Footer);
end;

procedure TSettingsView.BindingFooterResize(Sender: TObject);
begin
  var Footer := TLayout(Sender);
  var Caption := TLabel(Footer.Children[0]);
  var Editors := TLayout(Footer.Children[1]);
  if Footer.Width < 600 then
  begin
    Caption.Align := TAlignLayout.Top;
    Caption.Height := 24;
    Editors.Align := TAlignLayout.Bottom;
    Editors.Height := 32;
    Editors.Margins.Top := 0;
    Editors.Margins.Bottom := 0;
  end
  else
  begin
    Caption.Align := TAlignLayout.Client;
    Editors.Align := TAlignLayout.Right;
    Editors.Width := 268;
    Editors.Margins.Top := 14;
    Editors.Margins.Bottom := 14;
  end;
end;

procedure TSettingsView.SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
begin
  CancelCapture;
  Device.Capture.Tag := Action;
  Device.Clear.Tag := Action;
  Device.Caption.Text := Caption;
  Device.Capture.Text := 'Назначить · ' + BindingCaption(FInput, Action);
  Device.Capture.Visible := True;
  Device.Clear.Visible := True;
  CaptureClick(Device.Capture);
end;

procedure TSettingsView.CalloutClick(Sender: TObject);
begin
  if FBuilding or (FInput = nil) then
    Exit;
  var LabelControl := TLabel(Sender);
  for var D in FDevices do
    if D.Diagram = LabelControl.Parent then
    begin
      SelectBinding(D, LabelControl.Tag, LabelControl.TagString);
      Exit;
    end;
end;

procedure TSettingsView.RefreshBindings;
begin
  for var D in FDevices do
  begin
    if D.Diagram is TDeviceCallouts then
      TDeviceCallouts(D.Diagram).Refresh;
    if (D.Capture.Tag >= 0) and (D.Capture <> FCaptureButton) then
      D.Capture.Text := 'Назначить · ' + BindingCaption(FInput, D.Capture.Tag);
  end;
end;

procedure TSettingsView.VirtualDeviceChange(Sender: TObject);
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
  Notes: array[0..11] of string = ('C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B');
begin
  if FBuilding or (FInput = nil) then
    Exit;
  for var D in FDevices do
    if D.Control = Sender then
    begin
      var Action := -1;
      var Caption := '';
      if Sender is TScreenGamepad then
        for var B in TScreenGamepad(Sender).Buttons do
          if B in CoreButtons(SettingsCoreIds[FPage], D.Device) then
          begin
            Action := PadAction(D.Port, B);
            Caption := 'Кнопка ' + CoreButtonName(SettingsCoreIds[FPage], B);
            Break;
          end;
      if Sender is TNesPowerPad then
        for var B in TNesPowerPad(Sender).Buttons do
        begin
          Action := PowerPadAction + B - 1;
          Caption := 'Площадка ' + IntToStr(B);
          Break;
        end;
      if Sender is TNesSuborKeyboard then
        for var K in TNesSuborKeyboard(Sender).Keys do
        begin
          Action := SuborAction + Ord(K);
          Caption := 'Клавиша ' + Copy(GetEnumName(TypeInfo(TSuborKey), Ord(K)), 3, MaxInt);
          Break;
        end;
      if Sender is TNesFamicomKeyboard then
        for var K in TNesFamicomKeyboard(Sender).Keys do
        begin
          Action := FamicomAction + Ord(K);
          Caption := 'Клавиша ' + Copy(GetEnumName(TypeInfo(TFamicomKey), Ord(K)), 3, MaxInt);
          Break;
        end;
      if Sender is TNesMiraclePiano then
      begin
        for var K in TNesMiraclePiano(Sender).Keys do
        begin
          Action := PianoAction + K;
          if K < 49 then
            Caption := 'Нота ' + Notes[K mod 12] + IntToStr(2 + K div 12)
          else
            Caption := 'Кнопка пианино ' + IntToStr(K);
          Break;
        end;
        if Action < 0 then
          for var B in TNesMiraclePiano(Sender).Buttons do
          begin
            Action := PadAction(0, Mapping[B]);
            Caption := 'Кнопка ' + CoreButtonName('nes', Mapping[B]);
            Break;
          end;
      end;
      if Action < 0 then
        Exit;
      SelectBinding(D, Action, Caption);
      Exit;
    end;
end;

procedure TSettingsView.DeviceChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  var C := TComboBox(Sender);
  for var F in FFields do
    if F.Control = C then
      FDeviceIds[C.Tag] := F.Values[C.ItemIndex];
end;

procedure TSettingsView.RefreshDevicesClick(Sender: TObject);
begin
  CancelCapture;
  StorePage;
  FInput.Refresh;
  RequestRebuild;
end;

procedure TSettingsView.NavigationChange(Sender: TObject);
begin
  // TListBox.OnChange passes the selected item as Sender.
  SelectPage(FNavigation.ItemIndex);
end;

procedure TSettingsView.PagePickerChange(Sender: TObject);
begin
  SelectPage(FPagePicker.ItemIndex);
end;

procedure TSettingsView.SelectPage(Index: Integer);
begin
  if FBuilding or (Index < Low(SettingsPageNames)) or
    (Index > High(SettingsPageNames)) or (Index = FPage) then
    Exit;
  StorePage;
  FPage := Index;
  FBuilding := True;
  try
    FNavigation.ItemIndex := Index;
    FPagePicker.ItemIndex := Index;
  finally
    FBuilding := False;
  end;
  BuildPage;
end;

procedure TSettingsView.PortChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  StorePage;
  RequestRebuild;
end;

procedure TSettingsView.RequestRebuild;
begin
  if FRebuildPending then
    Exit;
  FRebuildPending := True;
  var Alive: TFunc<Boolean> := FAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;
      FRebuildPending := False;
      BuildPage(True);
    end);
end;

procedure TSettingsView.CaptureClick(Sender: TObject);
begin
  if (FInput = nil) or (TButton(Sender).Tag < 0) then
    Exit;
  CancelCapture;
  FCaptureButton := TButton(Sender);
  FCaptureAction := FCaptureButton.Tag;
  var Port := StrToIntDef(FCaptureButton.TagString, 0);
  FInput.BeginCapture(FCaptureAction, FDeviceIds[Port]);
  FCaptureDeadline := TThread.GetTickCount64 + 10000;
  FStatus.Text := 'Нажмите кнопку или направление. Esc — отмена. Ожидание: 10 секунд.';
  FCaptureButton.Text := 'Ожидание ввода…';
  FCancelCapture.Visible := True;
  Resize;
end;

procedure TSettingsView.ClearBindingClick(Sender: TObject);
begin
  CancelCapture;
  FInput.RemoveBindings(TButton(Sender).Tag);
  StorePage;
  RefreshBindings;
  FStatus.Text := 'Назначение удалено. Нажмите «Применить».';
  Resize;
end;

procedure TSettingsView.CancelCapture;
begin
  if FInput <> nil then
    FInput.CancelCapture;
  if FCaptureButton <> nil then
    FCaptureButton.Text := 'Назначить · ' + BindingCaption(FInput, FCaptureAction);
  FCaptureButton := nil;
  if FCancelCapture <> nil then
    FCancelCapture.Visible := False;
end;

procedure TSettingsView.CancelCaptureClick(Sender: TObject);
begin
  CancelCapture;
  FStatus.Text := 'Назначение отменено.';
  Resize;
end;

procedure TSettingsView.Poll;
begin
  if FCaptureButton = nil then
    Exit;
  var Binding: TInputBinding;
  if FInput.TakeCaptured(Binding) then
  begin
    if (Binding.Kind = TInputElementKind.Key) and (Binding.Code = 41) then
    begin
      CancelCaptureClick(Self);
      Exit;
    end;
    FInput.RemoveBindings(FCaptureAction);
    FInput.AddBinding(Binding);
    CancelCapture;
    RefreshBindings;
    FStatus.Text := 'Назначение сохранено в черновике. Нажмите «Применить».';
    Resize;
  end
  else if TThread.GetTickCount64 >= FCaptureDeadline then
    CancelCaptureClick(Self);
end;

procedure TSettingsView.PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback);
begin
  if Assigned(FPicker) then
  begin
    FPicker(Folder, Current, Callback);
    Exit;
  end;
  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.MultipleSelection := False;
    Dialog.InitialDirectory := Current;
    if not Folder then
      Dialog.InitialDirectory := ExtractFilePath(Current);
    Dialog.Title := 'Выбрать папку с ROM';
    if not Folder then
    begin
      Dialog.Title := 'Выбрать кассету';
      Dialog.Filter := 'Кассеты (*.tape)|*.tape|Все файлы|*.*';
      Dialog.FileMustExist := True;
    end;
    var Completion: TFMXSelectionCallback :=
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Callback(Result);
      end;
    if Folder then
      Dialog.SelectFolder(Completion)
    else
      Dialog.SelectFiles(Completion);
  finally
    Dialog.Free;
  end;
end;

procedure TSettingsView.PathClick(Sender: TObject);
begin
  CancelCapture;
  var Button := TEditButton(Sender);
  var Edit := TEdit(Button.TagObject);
  var Section, Key: string;
  for var F in FFields do
    if F.Control = Edit then
    begin
      Section := F.Section;
      Key := F.Key;
      Break;
    end;
  var Page := FPage;
  var Alive: TFunc<Boolean> := FAlive;
  PickLocation(Button.Tag = 1, Edit.Text,
    procedure(const Selection: TStorageSelection)
    begin
      if not Alive() then
        Exit;
      if Selection.Error <> '' then
        FStatus.Text := Selection.Error
      else if not Selection.Cancelled then
      begin
        FDrafts[Page].WriteString(Section, Key, Selection.Location);
        if FPage = Page then
          for var F in FFields do
            if (F.Section = Section) and (F.Key = Key) then
              TEdit(F.Control).Text := Selection.Location;
      end;
    end);
end;

procedure TSettingsView.ApplyClick(Sender: TObject);
begin
  try
    CancelCapture;
    StorePage;
    var Folder := FDrafts[0].ReadString('General', 'Path', '').Trim;
    {$IFNDEF ANDROID}
    if (Folder <> '') and not TDirectory.Exists(Folder) then
      raise Exception.Create('Папка с ROM не найдена. Выберите существующую папку.');
    {$ENDIF}
    if FDrafts[3].ReadBool('Input', 'FourScore', False) and
      ((FDrafts[3].ReadString('Ports', 'Port1', 'auto') = 'piano') or
      (FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'zapper') or
      (FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
      raise Exception.Create('Отключите Four Score для использования Zapper, Power Pad или Miracle Piano.');
    if (FDrafts[3].ReadString('Ports', 'Port1', 'auto') = 'piano') and
      ((FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'zapper') or
      (FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
      raise Exception.Create('Miracle Piano использует оба порта. Отключите Zapper или Power Pad.');
    // Config writes are per core and retain all settings that this UI does not expose.
    for var Ini in FDrafts do
      FStorage.WriteConfig(Ini);
    FStorage.RomFolder := Folder;
    if Assigned(FOnApply) then
      FOnApply(Self);
    FStatus.Text := 'Сохранено. Параметры ядра и состав портов применятся при следующем открытии ROM.';
  except
    on E: Exception do
      FStatus.Text := 'Не удалось сохранить параметры: ' + E.Message;
  end;
end;

procedure TSettingsView.BackClick(Sender: TObject);
begin
  CancelCapture;
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

initialization
  TPresentationProxyFactory.Current.Register(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

finalization
  TPresentationProxyFactory.Current.Unregister(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

end.

