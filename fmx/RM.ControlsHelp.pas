unit RM.ControlsHelp;

interface

uses
  Core.RomFormat, System.Classes, System.Types, System.UITypes, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Layouts, FMX.Objects, FMX.StdCtrls, FMXInput,
  Core.InputConfig, Core.Storage, FMX.Controls.Presentation;

function GameplayLabel(Owner: TComponent; Parent: TFmxObject; const Text: string; Size: Single): TLabel;

procedure GameplayButton(Button: TButton; const Text, Icon, Hint: string);

type
  TControlsHelpView = class(TFrame)
    FSurface: TRectangle;
    FHeader, FFooter, FContent, FLeft, FRight: TLayout;
    FScroll: TVertScrollBox;
    FTitle, FSubtitle, FNote, FDevice: TLabel;
    FSettings, FFooterClose: TButton;
    FPlayerTabs, FDiagram, FAssignments, FFunctions: TLayout;
    FDivider: TRectangle;
  private
    FInput: TInputManager;
    FOwnsInput: Boolean;
    FSystemId: string;
    FPorts: TCoreInputPorts;
    FPlayer, FPlayers: Integer;
    FPlayerButtons: array[0..7] of TButton;
    FOnClose, FOnSettings: TNotifyEvent;
    FArranging: Boolean;
    procedure PlayerClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure BuildPlayer;
    function Assignments(Action: Integer): string;
    procedure AssignmentRow(Parent: TLayout; const Caption, Keys: string; Y: Single; Action: Integer = -1);
  protected
    procedure Resize; override;
  public
    constructor CreateHelp(AOwner: TComponent; Input: TInputManager; const SystemId: string; const Ports: TCoreInputPorts; Players: Integer; KeyboardPeripheral: Boolean; const Storage: IStorage; HasCoinAcceptor: Boolean = False);
    destructor Destroy; override;
    property Player: Integer read FPlayer;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
    property OnSettings: TNotifyEvent read FOnSettings write FOnSettings;
  end;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, FMX.Graphics,
  FMX.BehaviorManager, RM.LibraryView, RM.Settings, RM.Input, RM.Gamepad,
  Core.Emulation, RM.Icons, RM.Styles;

{$R *.fmx}

type
  THelpInputBackend = class(TInputBackend)
    procedure Refresh; override;
    function Poll: TArray<TInputValue>; override;
  end;

procedure THelpInputBackend.Refresh;
begin
end;

function THelpInputBackend.Poll: TArray<TInputValue>;
begin
  Result := nil;
end;

function GameplayLabel(Owner: TComponent; Parent: TFmxObject; const Text: string; Size: Single): TLabel;
begin
  Result := TLabel.Create(Owner);
  Result.Parent := Parent;
  Result.Text := Text;
  Result.StyledSettings := [];
  Result.TextSettings.Font.Family := 'Segoe UI';
  Result.TextSettings.Font.Size := Size;
  Result.TextSettings.FontColor := $FFE8ECF1;
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
  Result.HitTest := False;
end;

procedure GameplayButton(Button: TButton; const Text, Icon, Hint: string);
begin
  Button.Text := Text;
  Button.Hint := Hint;
  Button.ShowHint := True;
  Button.CanFocus := False;
  Button.StyledSettings := [];
  Button.TextSettings.Font.Family := 'Segoe UI';
  Button.TextSettings.Font.Size := 13;
  Button.TextSettings.FontColor := $FFE8ECF1;
  Button.TextSettings.Trimming := TTextTrimming.Character;
  Button.TextSettings.WordWrap := False;
  Button.StyleLookup := 'buttonstyle';
  if Icon <> '' then
  begin
    InterfaceIcon(Button, Icon, 12, 10, 20);
    Button.StylesData['text.Margins.Left'] := 36;
    Button.StylesData['text.Margins.Right'] := 10;
  end;
end;

constructor TControlsHelpView.CreateHelp(AOwner: TComponent; Input: TInputManager; const SystemId: string; const Ports: TCoreInputPorts; Players: Integer; KeyboardPeripheral: Boolean; const Storage: IStorage; HasCoinAcceptor: Boolean);
begin
  inherited Create(AOwner);
  Name := 'ControlsHelp';
  FInput := Input;
  if FInput = nil then
  begin
    FInput := TInputManager.Create(THelpInputBackend.Create);
    FOwnsInput := True;
    var Ini := Storage.ReadConfig(Storage.ConfigFile(SystemId));
    try
      LoadInputBindings(FInput, Ini, SystemId);
      FilterInputBindings(FInput, Ini);
    finally
      Ini.Free;
    end;
  end;
  FSystemId := SystemId;
  FPorts := Ports;
  FPlayers := EnsureRange(Players, 1, 8);
  FormStyles.RelocalizeUI(Self, 'en');
  FSubtitle.Text := Translate('Current bindings · ') + LibrarySystemName(SystemId) + Translate(' · game paused');
  if KeyboardPeripheral then
    FNote.Text := Translate('Letter shortcuts, F5, F6 and F8 are unavailable with keyboard peripherals.');
  if KeyboardPeripheral and HasCoinAcceptor then
    FNote.Text := Translate('Letter shortcuts, F5, F6, F8 and F9 are unavailable with keyboard peripherals.');
  FSettings.OnClick := SettingsClick;
  FSettings.StylesData['text.Margins.Left'] := 36;
  FSettings.StylesData['text.Margins.Right'] := 10;
  FFooterClose.OnClick := CloseClick;
  for var I := 0 to High(FPlayerButtons) do
  begin
    FPlayerButtons[I] := FindComponent('Player' + IntToStr(I + 1)) as TButton;
    FPlayerButtons[I].Text := Translate('Player ') + IntToStr(I + 1);
    FPlayerButtons[I].Visible := I < FPlayers;
    FPlayerButtons[I].OnClick := PlayerClick;
  end;
  for var I := 0 to 9 do
  begin
    var Row := FindComponent('Function' + IntToStr(I)) as TLayout;
    if KeyboardPeripheral and (I in [1, 2, 3, 4, 6, 7, 9]) then
      Row.Opacity := 0.4;
    if I = 9 then
      Row.Visible := HasCoinAcceptor;
  end;
  FFunctions.Height := (9 + Ord(HasCoinAcceptor)) * 44;
  BuildPlayer;
end;

function TControlsHelpView.Assignments(Action: Integer): string;
begin
  Result := '';
  if FInput = nil then
    Exit(Translate('Unassigned'));
  for var B in FInput.Bindings do
    if B.Action = Action then
    begin
      var Caption := '';
      if B.Kind = TInputElementKind.Key then
        Caption := InputKeyName(B.Code)
      else
      begin
        Caption := Format(Translate('Button %d'), [B.Code + 1]);
        if B.Kind = TInputElementKind.Axis then
          Caption := Format(Translate('Axis %d (%d)'), [B.Code, B.Direction]);
        if B.Kind = TInputElementKind.Hat then
          Caption := Format('D-pad %d', [B.Direction]);
        if B.DeviceId = SystemMouseId then
          Caption := Translate(MouseElementName(B.Kind, B.Code))
        else
          for var D in FInput.Devices do
            if D.Id = B.DeviceId then
            begin
              for var E in D.Elements do
                if (E.Kind = B.Kind) and (E.Code = B.Code) then
                begin
                  Caption := E.Name;
                  if B.Kind in [TInputElementKind.Axis, TInputElementKind.RelativeAxis] then
                    if B.Direction < 0 then
                      Caption := Caption + ' (−)'
                    else
                      Caption := Caption + ' (+)';
                  if B.Kind = TInputElementKind.Hat then
                    Caption := Caption + Format(' (%d)', [B.Direction]);
                end;
              Caption := D.Name + ': ' + Caption;
              Break;
            end;
      end;
      if Result <> '' then
        Result := Result + ' · ';
      Result := Result + Caption;
    end;
  if Result = '' then
    Result := Translate('Unassigned');
end;

procedure TControlsHelpView.AssignmentRow(Parent: TLayout; const Caption, Keys: string; Y: Single; Action: Integer);
begin
  var Row := TLayout.Create(Parent);
  Row.Parent := Parent;
  Row.Align := TAlignLayout.Top;
  Row.Height := 34;
  if Parent = FFunctions then
    Row.Height := 44;
  Row.Position.Y := Y;
  var L := GameplayLabel(Row, Row, Caption, 13);
  L.Align := TAlignLayout.Left;
  L.Width := 66;
  if Parent = FFunctions then
    L.Width := 260;
  var Key := TRectangle.Create(Row);
  Key.Parent := Row;
  Key.Align := TAlignLayout.Client;
  Key.Margins.Rect := TRectF.Create(8, 4, 0, 4);
  Key.Fill.Color := $FF1B2126;
  Key.Stroke.Color := $FF586572;
  Key.XRadius := 5;
  Key.YRadius := 5;
  Key.HitTest := False;
  L := GameplayLabel(Row, Key, Keys, 12);
  L.Align := TAlignLayout.Client;
  L.Margins.Rect := TRectF.Create(8, 0, 8, 0);
  L.TextSettings.HorzAlign := TTextAlign.Center;
  L.Tag := Action;
  L.Hint := Keys;
  L.ShowHint := True;
  L.HitTest := True;
end;

procedure TControlsHelpView.BuildPlayer;
begin
  FDiagram.DeleteChildren;
  FAssignments.DeleteChildren;
  FAssignments.Height := 0;
  for var i := 0 to FPlayers - 1 do
    if i = FPlayer then
      FPlayerButtons[i].StyleLookup := 'buttonstyle_accent'
    else
      FPlayerButtons[i].StyleLookup := 'buttonstyle';
  var Buttons := CoreButtons(FSystemId, FPorts.Devices[FPlayer]);
  var Devices := TStringList.Create;
  try
    if FInput <> nil then
      for var B in FInput.Bindings do
        if ((FPlayer < 4) and (B.Action >= FPlayer * 32) and (B.Action <= FPlayer * 32 + Ord(High(TEmulatorButton)))) or
          ((FPlayer >= 4) and (B.Action >= ExtraPadAction + (FPlayer - 4) * 32) and
          (B.Action <= ExtraPadAction + (FPlayer - 4) * 32 + Ord(High(TEmulatorButton)))) then
        begin
          var Name := B.DeviceId;
          if B.DeviceId = SystemKeyboardId then
            Name := Translate('Keyboard')
          else
            for var D in FInput.Devices do
              if D.Id = B.DeviceId then
              begin
                Name := D.Name;
                Break;
              end;
          if Devices.IndexOf(Name) < 0 then
            Devices.Add(Name);
        end;
    FDevice.Text := Devices.DelimitedText.Replace('"', '').Replace(',', ' · ');
  finally
    Devices.Free;
  end;
  if Buttons = [] then
  begin
    var L := GameplayLabel(Self, FDiagram, Translate('No controller is connected to this port. Choose a device in the controls settings.'), 14);
    L.Align := TAlignLayout.Client;
    L.TextSettings.WordWrap := True;
  end
  else
  begin
    var Pad := TScreenGamepad.Create(FDiagram);
    Pad.HitTest := False;
    if FSystemId = ROM_SYSTEM_SNES then
      Pad.Layout := TScreenGamepadLayout.Snes
    else if FSystemId = ROM_SYSTEM_MD then
      Pad.Layout := TScreenGamepadLayout.Sega
    else if FSystemId = ROM_SYSTEM_GB then
      Pad.Layout := TScreenGamepadLayout.GameBoy
    else if FSystemId = ROM_SYSTEM_GBC then
      Pad.Layout := TScreenGamepadLayout.GameBoyColor
    else if FSystemId = ROM_SYSTEM_NEOGEO then
      Pad.Layout := TScreenGamepadLayout.NeoGeo;
    Pad.ButtonMask := Buttons;
    var Diagram := TDeviceCallouts.Create(FDiagram);
    Diagram.Parent := FDiagram;
    Diagram.Align := TAlignLayout.Client;
    Diagram.Configure(Pad, FInput, FSystemId, FPlayer, nil);
    // This diagram is a reference; it cannot capture or forward controller input.
    Diagram.HitTest := False;
    for var Child in Diagram.Children do
      if Child is TControl then
        TControl(Child).HitTest := False;
    var Y: Single := 0;
    for var B in Buttons do
    begin
      AssignmentRow(FAssignments, CoreButtonName(FSystemId, B), Assignments(PadAction(FPlayer, B)), Y, PadAction(FPlayer, B));
      Y := Y + 34;
    end;
    FAssignments.Height := Y;
  end;
  Resize;
end;

procedure TControlsHelpView.Resize;
begin
  inherited;
  if (csLoading in ComponentState) or FArranging or (FSurface = nil) or (FFunctions = nil) or (csDestroying in ComponentState) then
    Exit;
  FArranging := True;
  try
    var W := Max(240, Min(1080, Width - 40));
    var H := Max(260, Min(740, Height - 40));
    FSurface.SetBounds((Width - W) / 2, (Height - H) / 2, W, H);
    FHeader.SetBounds(24, 20, W - 48, 70);
    FTitle.SetBounds(60, 0, W - 154, 36);
    FSubtitle.SetBounds(60, 38, W - 130, 24);
    FTitle.TextSettings.Font.Size := IfThen(W < 650, 18, 25);
    FFooter.SetBounds(24, H - 98, W - 48, 78);
    FNote.SetBounds(0, 0, W - 48, 24);
    var CloseW := IfThen(W < 500, 100, 144);
    FSettings.SetBounds(0, 30, Min(230, W - 60 - CloseW), 40);
    FFooterClose.SetBounds(W - 48 - CloseW, 30, CloseW, 40);
    if W < 500 then
      FSettings.Text := Translate('Settings')
    else
      FSettings.Text := Translate('Configure controls');
    FScroll.SetBounds(24, 100, W - 48, Max(80, H - 214));
    var ContentW := W - 62;
    var ColumnW := ContentW;
    var TwoColumns := W >= 850;
    if TwoColumns then
      ColumnW := (ContentW - 48) * 0.56;
    var TabColumns := Max(1, Trunc(ColumnW / 108));
    var TabsRows := Ceil(FPlayers / TabColumns);
    FPlayerTabs.SetBounds(0, 38, ColumnW, TabsRows * 38);
    for var i := 0 to FPlayers - 1 do
      FPlayerButtons[i].SetBounds((i mod TabColumns) * 108, (i div TabColumns) * 38, 100, 32);
    FDevice.SetBounds(0, 40 + TabsRows * 38, ColumnW, 24);
    FDiagram.SetBounds(0, 74 + TabsRows * 38, ColumnW, 180);
    var AssignmentColumns := 1;
    if ColumnW >= 380 then
      AssignmentColumns := 2;
    var Rows := Ceil(FAssignments.ChildrenCount / AssignmentColumns);
    FAssignments.SetBounds(0, 266 + TabsRows * 38, ColumnW, Rows * 34);
    for var i := 0 to FAssignments.ChildrenCount - 1 do
    begin
      var Row := TControl(FAssignments.Children[i]);
      Row.Align := TAlignLayout.None;
      Row.SetBounds((i div Max(1, Rows)) * ColumnW / AssignmentColumns,
        (i mod Max(1, Rows)) * 34, ColumnW / AssignmentColumns - 10, 34);
      TControl(Row.Children[0]).Width := 40;
    end;
    var LeftH := 270 + TabsRows * 38 + FAssignments.Height;
    FLeft.SetBounds(0, 0, ColumnW, LeftH);
    var RightW := ContentW;
    if TwoColumns then
      RightW := ContentW - ColumnW - 48;
    FRight.SetBounds(IfThen(TwoColumns, ColumnW + 48, 0), IfThen(TwoColumns, 0, LeftH + 24), RightW, FFunctions.Height + 72);
    FFunctions.SetBounds(0, 70, RightW, FFunctions.Height);
    for var Row in FFunctions.Children do
      TControl(TFmxObject(Row).Children[0]).Width := Max(120, RightW - 128);
    FDivider.Visible := TwoColumns;
    FDivider.SetBounds(ColumnW + 24, 0, 1, Max(LeftH, FRight.Height));
    FContent.SetBounds(0, 0, ContentW, IfThen(TwoColumns, Max(LeftH, FRight.Height), LeftH + 24 + FRight.Height));
  finally
    FArranging := False;
  end;
end;

procedure TControlsHelpView.PlayerClick(Sender: TObject);
begin
  FPlayer := TButton(Sender).Tag;
  BuildPlayer;
end;

procedure TControlsHelpView.CloseClick(Sender: TObject);
begin
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

procedure TControlsHelpView.SettingsClick(Sender: TObject);
begin
  if Assigned(FOnSettings) then
    FOnSettings(Self);
end;

destructor TControlsHelpView.Destroy;
begin
  if FOwnsInput then
    FInput.Free;
  inherited;
end;

end.

