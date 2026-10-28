unit RM.ControlsHelp;

interface

uses
  System.Classes, RM.ControlsHelp.Content, RM.ControlsHelp.Shortcut,
  System.Types, System.UITypes, FMX.Types, FMX.Controls, FMX.Forms, FMX.Layouts,
  FMX.Objects, FMX.StdCtrls, FMXInput, Core.InputConfig, Core.Storage,
  FMX.Controls.Presentation;

type
  TControlsHelpView = class(TFrame)
    RectangleSurface: TRectangle;
    LayoutHeader, LayoutFooter, LayoutContent, LayoutLeft, LayoutRight: TLayout;
    VertScrollBoxScroll: TVertScrollBox;
    LabelTitle, LabelSubtitle, LabelNote, LabelDevice: TLabel;
    ButtonSettings, ButtonFooterClose: TButton;
    LayoutPlayerTabs, LayoutDiagram, LayoutAssignments, LayoutFunctions: TLayout;
    RectangleDivider: TRectangle;
  private
    FInput: TInputManager;
    FContent: TPlatformControlsHelpClass;
    FInfo: TControlsHelpInfo;
    FKeyboardPeripheral, FHasCoinAcceptor: Boolean;
    FOwnsInput: Boolean;
    FSystemId: string;
    FPorts: TCoreInputPorts;
    FPlayer, FPlayers: Integer;
    FPlayerButtons: array[0..7] of TButton;
    FOnClose, FOnSettings: TNotifyEvent;
    FArranging: Boolean;
    function HelpContext: TControlsHelpContext;
    procedure BuildShortcuts;
    procedure BuildPlayer;
    function Assignments(Action: Integer): string;
    procedure AssignmentRow(Parent: TLayout; const Caption, Keys: string; Y: Single; Action: Integer = -1);
    procedure PlayerClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
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
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, FMX.Graphics, FMX.TextLayout, FMX.BehaviorManager,
  RM.LibraryView, Core.Emulation, RM.Input, RM.Settings.Rendering, RM.Styles;

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

constructor TControlsHelpView.CreateHelp(AOwner: TComponent; Input: TInputManager; const SystemId: string; const Ports: TCoreInputPorts; Players: Integer; KeyboardPeripheral: Boolean; const Storage: IStorage; HasCoinAcceptor: Boolean);
begin
  FInfo.AssignmentColumns := 2;
  FInfo.AssignmentRowHeight := 34;
  FInfo.AssignmentCaptionWidth := 40;
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
      FilterInputBindings(FInput, Ini, SystemId);
    finally
      Ini.Free;
    end;
  end;
  FSystemId := SystemId;
  FPorts := Ports;
  FKeyboardPeripheral := KeyboardPeripheral;
  FHasCoinAcceptor := HasCoinAcceptor;
  FContent := PlatformControlsHelp(SystemId);

  FPlayers := EnsureRange(Players, 1, 8);
  FormStyles.RelocalizeUI(Self, 'en');
  FInfo := FContent.Info(HelpContext);
  (FindComponent('LabelControllerTitle') as TLabel).Text := FInfo.ControllerTitle;
  LabelSubtitle.Text := Translate('Current bindings · ') + LibrarySystemName(SystemId) + Translate(' · game paused');
  LabelNote.Text := FInfo.Note;
  ButtonSettings.OnClick := SettingsClick;
  ButtonSettings.StylesData['text.Margins.Left'] := 36;
  ButtonSettings.StylesData['text.Margins.Right'] := 10;
  ButtonFooterClose.OnClick := CloseClick;
  for var i := 0 to High(FPlayerButtons) do
  begin
    FPlayerButtons[i] := FindComponent('ButtonPlayer' + IntToStr(i + 1)) as TButton;
    FPlayerButtons[i].Text := Translate('Player ') + IntToStr(i + 1);
    FPlayerButtons[i].Visible := i < FPlayers;
    FPlayerButtons[i].OnClick := PlayerClick;
  end;
  BuildShortcuts;
  BuildPlayer;
end;

procedure RetireHelpChildren(Parent: TControl);
begin
  if Parent = nil then
    Exit;
  if Parent.ChildrenCount > 0 then
    for var Child in Parent.Children.ToArray do
      if Child is TControl then
        RetireSettingsControl(TControl(Child));
end;

procedure DisableDiagramInput(Control: TControl);
begin
  Control.HitTest := False;
  if Control.ChildrenCount > 0 then
    for var Child in Control.Children do
      if Child is TControl then
        DisableDiagramInput(TControl(Child));
end;

function TControlsHelpView.HelpContext: TControlsHelpContext;
begin
  Result.SystemId := FSystemId;
  Result.Ports := FPorts;
  Result.Player := FPlayer;
  Result.KeyboardPeripheral := FKeyboardPeripheral;
  Result.HasCoinAcceptor := FHasCoinAcceptor;
  Result.Input := FInput;
end;

procedure TControlsHelpView.BuildShortcuts;
const
  Ids: array[0..10] of string = ('help', 'save', 'load', 'screenshot', 'pause', 'fullscreen',
    'reset', 'hard-restart', 'open', 'exit-fullscreen', 'coin');
  Suffixes: array[0..10] of string = ('0', '1', '2', '3', '4', '5', '6', 'HardRestart', '7', '8', '9');
begin
  var Y: Single := 0;
  for var I := 0 to High(Ids) do
  begin
    var Row := FindComponent('LayoutFunction' + Suffixes[I]) as TLayout;
    Row.TagString := Ids[I];
    Row.Visible := (Ids[I] <> 'coin') or FHasCoinAcceptor;
    Row.Opacity := 1;
    if not FContent.StandardShortcutAvailable(HelpContext, Ids[I]) then
      Row.Opacity := 0.4;
    if Row.Visible then
    begin
      Row.Position.Y := Y;
      Y := Y + Row.Height;
    end;
  end;
  var Shortcuts := FContent.Shortcuts(HelpContext);
  for var I := 0 to High(Shortcuts) do
  begin
    var Row := TControlsHelpShortcutView.Create(LayoutFunctions);
    Row.Name := '';
    Row.Parent := LayoutFunctions;
    Row.Position.Y := Y; // Aligned rows follow the complete standard group.
    Row.Configure(Shortcuts[I]);
    Y := Y + Row.Height;
  end;
  LayoutFunctions.Height := Y;
end;

destructor TControlsHelpView.Destroy;
begin
  RetireHelpChildren(LayoutDiagram);
  for var I := 0 to 1 do
    RetireHelpChildren(FindComponent('LayoutAssignmentColumn' + IntToStr(I)) as TLayout);
  if FOwnsInput then
    FInput.Free;
  inherited;
end;

procedure TControlsHelpView.BuildPlayer;
begin
  RetireHelpChildren(LayoutDiagram);
  LayoutDiagram.Visible := True;
  for var i := 0 to 1 do
    RetireHelpChildren(TLayout(FindComponent('LayoutAssignmentColumn' + IntToStr(i))));
  LayoutAssignments.Height := 0;
  for var i := 0 to FPlayers - 1 do
    if i = FPlayer then
      FPlayerButtons[i].StyleLookup := 'buttonstyle_accent'
    else
      FPlayerButtons[i].StyleLookup := 'buttonstyle';
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
    LabelDevice.Text := Devices.DelimitedText.Replace('"', '').Replace(',', ' · ');
  finally
    Devices.Free;
  end;
  var Diagram := FContent.CreateDiagram(HelpContext, LayoutDiagram);
  if Diagram = nil then
  begin
    var L := GameplayLabel(Self, LayoutDiagram, Translate('No controller is connected to this port. Choose a device in the controls settings.'), 14);
    L.Align := TAlignLayout.Client;
    L.TextSettings.WordWrap := True;
  end
  else
  begin
    Diagram.Parent := LayoutDiagram;
    Diagram.Align := TAlignLayout.Client;
    DisableDiagramInput(Diagram);
    var Y: Single := 0;
    for var Binding in FContent.Assignments(HelpContext) do
    begin
      AssignmentRow(LayoutAssignments, Binding.Caption, Assignments(Binding.Action), Y, Binding.Action);
      Y := Y + 34;
    end;
    LayoutAssignments.Height := Y;
  end;
  Resize;
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
  if Parent = LayoutAssignments then
    Row.Parent := FindComponent('LayoutAssignmentColumn0') as TLayout;
  Row.Align := TAlignLayout.Top;
  Row.Tag := Round(Y);
  Row.Height := 34;
  if Parent = LayoutFunctions then
    Row.Height := 44;
  Row.Position.Y := Y; // Top-alignment ordering key for generated bindings.
  var L := GameplayLabel(Row, Row, Translate(Caption), 13);
  L.Align := TAlignLayout.Left;
  L.Width := 160;
  if Parent = LayoutFunctions then
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

procedure TControlsHelpView.Resize;
begin
  inherited;
  if (csLoading in ComponentState) or FArranging or (RectangleSurface = nil) or (LayoutFunctions = nil) or (csDestroying in ComponentState) then
    Exit;
  FArranging := True;
  try
    var W := Max(1, Min(1080, Width - 40));
    var H := Max(1, Min(740, Height - 40));
    RectangleSurface.Width := W;
    RectangleSurface.Height := H;
    var NoteLayout := TTextLayoutManager.DefaultTextLayout.Create;
    try
      NoteLayout.BeginUpdate;
      NoteLayout.Font.Assign(LabelNote.TextSettings.Font);
      NoteLayout.MaxSize := PointF(Max(1, W - 48), 100000);
      NoteLayout.WordWrap := True;
      NoteLayout.Text := LabelNote.Text;
      NoteLayout.EndUpdate;
      LabelNote.Height := Max(24, Ceil(NoteLayout.TextHeight) + 8);
      LayoutFooter.Height := LabelNote.Height + 54;
    finally
      NoteLayout.Free;
    end;
    LabelTitle.TextSettings.Font.Size := IfThen(W < 650, 18, 25);
    var CloseW := IfThen(W < 500, 100, 144);
    ButtonFooterClose.Width := CloseW;
    ButtonSettings.Width := Max(1, Min(230, W - 60 - CloseW));
    if W < 500 then
      ButtonSettings.Text := Translate('Settings')
    else
      ButtonSettings.Text := Translate('Configure controls');
    var ContentW := Max(1, W - 62);
    var TwoColumns := W >= 850;
    var ColumnW := ContentW;
    if TwoColumns then
      ColumnW := (ContentW - 48) * 0.56;
    LayoutLeft.Align := TAlignLayout.Top;
    LayoutRight.Align := TAlignLayout.Top;
    LayoutRight.Margins.Rect := RectF(0, 24, 0, 0);
    RectangleDivider.Visible := TwoColumns;
    if TwoColumns then
    begin
      LayoutLeft.Align := TAlignLayout.Left;
      LayoutLeft.Width := ColumnW;
      LayoutRight.Align := TAlignLayout.Client;
      LayoutRight.Margins.Rect := RectF(24, 0, 0, 0);
    end;
    var TabColumns := Max(1, Trunc(ColumnW / 108));
    var TabRows := Ceil(FPlayers / TabColumns);
    LayoutPlayerTabs.BeginUpdate;
    try
      for var i := 0 to 7 do
        TLayout(FindComponent('LayoutPlayerTabRow' + IntToStr(i))).Visible := i < TabRows;
      for var i := 0 to FPlayers - 1 do
      begin
        var Row := FindComponent('LayoutPlayerTabRow' + IntToStr(i div TabColumns)) as TLayout;
        Row.Position.Y := (i div TabColumns) * 38; // Alignment ordering key.
        FPlayerButtons[i].Parent := Row;
        FPlayerButtons[i].Position.X := (i mod TabColumns) * 108;
      end;
      LayoutPlayerTabs.Height := TabRows * 38;
    finally
      LayoutPlayerTabs.EndUpdate;
    end;
    var AssignmentColumns := 1;
    if (FInfo.AssignmentColumns > 1) and (ColumnW >= 380) then
      AssignmentColumns := Min(2, FInfo.AssignmentColumns);
    var AllRows := TList<TControl>.Create;
    try
      for var i := 0 to 1 do
      begin
        var Column := FindComponent('LayoutAssignmentColumn' + IntToStr(i)) as TLayout;
        if Column.Children <> nil then
          for var Child in Column.Children do
            AllRows.Add(TControl(Child));
      end;
      AllRows.Sort(TComparer<TControl>.Construct(
        function(const A, B: TControl): Integer
        begin
          Result := CompareValue(A.Tag, B.Tag);
        end));
      var Rows := Ceil(AllRows.Count / AssignmentColumns);
      var RowHeight := FInfo.AssignmentRowHeight;
      for var i := 0 to 1 do
      begin
        var Column := FindComponent('LayoutAssignmentColumn' + IntToStr(i)) as TLayout;
        Column.Visible := i < AssignmentColumns;
        Column.Width := ColumnW / AssignmentColumns;
        Column.Height := Rows * RowHeight;
      end;
      for var i := 0 to AllRows.Count - 1 do
      begin
        var Row := AllRows[i];
        Row.Parent := FindComponent('LayoutAssignmentColumn' + IntToStr(i div Max(1, Rows))) as TLayout;
        Row.Align := TAlignLayout.Top;
        Row.Height := RowHeight;
        Row.Margins.Right := IfThen(AssignmentColumns = 2, 10, 0);
        Row.Position.Y := (i mod Max(1, Rows)) * RowHeight;
        TControl(Row.Children[0]).Width := FInfo.AssignmentCaptionWidth;
      end;
      LayoutAssignments.Height := Rows * RowHeight;
    finally
      AllRows.Free;
    end;
    LayoutLeft.Height := 30 + 8 + LayoutPlayerTabs.Height + 2 + 24 + 12 + LayoutAssignments.Height;
    if LayoutDiagram.Visible then
      LayoutLeft.Height := LayoutLeft.Height + 10 + 180;
    LayoutRight.Height := LayoutFunctions.Height + 70;
    var CaptionWidth := Max(120, IfThen(TwoColumns, ContentW - ColumnW - 48, ContentW) - 128);
    if LayoutFunctions.ChildrenCount > 0 then
      for var Child in LayoutFunctions.Children do
        if Child is TControlsHelpShortcutView then
          TControlsHelpShortcutView(Child).SetCaptionWidth(CaptionWidth)
        else if (Child is TControl) and (Child.ChildrenCount > 0) then
          TControl(Child.Children[0]).Width := CaptionWidth;
    if TwoColumns then
      LayoutContent.Height := Max(LayoutLeft.Height, LayoutRight.Height)
    else
      LayoutContent.Height := LayoutLeft.Height + 24 + LayoutRight.Height;
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

end.

