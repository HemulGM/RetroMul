unit RM.Dialogs;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Layouts, FMX.Objects, FMX.StdCtrls,
  FMX.Controls.Presentation;

type
  TRetroDialogKind = (Information, Warning, Error, Confirmation, Loading);
  TRetroDialogChoice = (Accept, Alternative, Cancel);

  TRetroDialog = class(TFrame)
    RectangleBackdrop: TRectangle;
    PanelCard: TPanel;
    RectangleAccent: TRectangle;
    CircleBadge: TCircle;
    LabelBadge, LabelTitle, LabelMessage: TLabel;
    VertScrollBoxMessage: TVertScrollBox;
    ButtonClose, ButtonCancel, ButtonAccept, ButtonAlternative: TButton;
  private
    FReady, FConfirmation, FLoading, FCustomActions, FArranging: Boolean;
    FBusyIndicator: TAniIndicator;
    FOnResult: TProc<Boolean>;
    FOnAlternative: TProc;
    procedure AcceptClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure AlternativeClick(Sender: TObject);
    procedure Arrange;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Configure(const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>;
      const AcceptText: string = ''; const CancelText: string = '';
      const AlternativeText: string = ''; const OnAlternative: TProc = nil);
    procedure FocusDefault;
    procedure HandleKey(var Key: Word; var KeyChar: WideChar);
  end;

// All dialogs are asynchronous and belong to the host form. Call on the UI thread.
procedure ShowRetroMessage(Owner: TComponent; const Text: string; Kind: TRetroDialogKind = TRetroDialogKind.Error);

procedure ShowRetroConfirmation(Owner: TComponent; const Text: string; const OnResult: TProc<Boolean>;
  const AcceptText: string = ''; const CancelText: string = '');

procedure ShowRetroChoice(Owner: TComponent; const Text: string; const OnResult: TProc<TRetroDialogChoice>;
  const AcceptText, AlternativeText, CancelText: string);

procedure ShowRetroLoading(Owner: TComponent; const Text: string; const OnCancel: TProc);

procedure CloseRetroLoading(Owner: TComponent);

procedure SetRetroDialogActivity(Owner: TCustomForm; OnActivity: TNotifyEvent);

function RetroDialogVisible(Owner: TCustomForm): Boolean;

function HandleRetroDialogKey(Owner: TCustomForm; var Key: Word; var KeyChar: WideChar): Boolean;

implementation

uses
  System.Math, System.Generics.Collections, FMX.TextLayout, FMX.Graphics,
  RM.Icons;

{$R *.fmx}

type
  TDialogRequest = class
    Requester: TComponent;
    Text: string;
    AcceptText, CancelText, AlternativeText: string;
    OnAlternative: TProc;
    Kind: TRetroDialogKind;
    OnResult: TProc<Boolean>;
  end;

  TRetroDialogHost = class(TComponent)
  private
    FForm: TCustomForm;
    FDialog: TRetroDialog;
    FQueue: TObjectList<TDialogRequest>;
    FActive: TDialogRequest;
    FBlocked: TList<TControl>;
    FPreviousFocus: TControl;
    FCompleting, FModal: Boolean;
    FOnActivity: TNotifyEvent;
    procedure BeginModal;
    procedure EndModal;
    procedure ShowNext;
    procedure Complete(Confirmed: Boolean; InvokeCallback: Boolean = True; Alternative: Boolean = False);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Enqueue(Requester: TComponent; const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>;
      const AcceptText: string = ''; const CancelText: string = '';
      const AlternativeText: string = ''; const OnAlternative: TProc = nil);
  end;

function FindHost(Form: TCustomForm; CreateIfMissing: Boolean): TRetroDialogHost;
begin
  Result := nil;
  if (Form = nil) or (csDestroying in Form.ComponentState) then
    Exit;

  for var i := 0 to Form.ComponentCount - 1 do
    if Form.Components[i] is TRetroDialogHost then
      Exit(TRetroDialogHost(Form.Components[i]));

  if CreateIfMissing then
    Result := TRetroDialogHost.Create(Form);
end;

function OwnerForm(Owner: TComponent): TCustomForm;
begin
  while Owner <> nil do
  begin
    if Owner is TCustomForm then
      Exit(TCustomForm(Owner));

    if (Owner is TControl) and (TControl(Owner).Root <> nil) and (TControl(Owner).Root.GetObject is TCustomForm) then
      Exit(TCustomForm(TControl(Owner).Root.GetObject));

    Owner := Owner.Owner;
  end;
  Result := nil;
  if Application.MainForm is TCustomForm then
    Result := TCustomForm(Application.MainForm);
end;

procedure ShowRetroMessage(Owner: TComponent; const Text: string; Kind: TRetroDialogKind);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, Kind, nil);
end;

procedure ShowRetroConfirmation(Owner: TComponent; const Text: string; const OnResult: TProc<Boolean>;
  const AcceptText, CancelText: string);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, TRetroDialogKind.Confirmation, OnResult, AcceptText, CancelText);
end;

procedure ShowRetroChoice(Owner: TComponent; const Text: string; const OnResult: TProc<TRetroDialogChoice>;
  const AcceptText, AlternativeText, CancelText: string);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, TRetroDialogKind.Confirmation,
      procedure(Confirmed: Boolean)
      begin
        if not Assigned(OnResult) then Exit;
        if Confirmed then OnResult(TRetroDialogChoice.Accept)
        else OnResult(TRetroDialogChoice.Cancel);
      end, AcceptText, CancelText, AlternativeText,
      procedure
      begin
        if Assigned(OnResult) then OnResult(TRetroDialogChoice.Alternative);
      end);
end;

procedure SetRetroDialogActivity(Owner: TCustomForm; OnActivity: TNotifyEvent);
begin
  var Host := FindHost(Owner, True);
  if Host <> nil then
    Host.FOnActivity := OnActivity;
end;

procedure ShowRetroLoading(Owner: TComponent; const Text: string; const OnCancel: TProc);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, TRetroDialogKind.Loading,
      procedure(Confirmed: Boolean)
      begin
        if Assigned(OnCancel) then
          OnCancel();
      end);
end;

procedure CloseRetroLoading(Owner: TComponent);
begin
  var Host := FindHost(OwnerForm(Owner), False);
  if Host = nil then
    Exit;

  for var i := Host.FQueue.Count - 1 downto 0 do
    if (Host.FQueue[i].Requester = Owner) and (Host.FQueue[i].Kind = TRetroDialogKind.Loading) then
      Host.FQueue.Delete(i);
  if (Host.FActive <> nil) and (Host.FActive.Requester = Owner) and (Host.FActive.Kind = TRetroDialogKind.Loading) then
    Host.Complete(False, False);
end;

function RetroDialogVisible(Owner: TCustomForm): Boolean;
begin
  var Host := FindHost(Owner, False);
  Result := (Host <> nil) and Host.FModal;
end;

function HandleRetroDialogKey(Owner: TCustomForm; var Key: Word; var KeyChar: WideChar): Boolean;
begin
  var Host := FindHost(Owner, False);
  Result := (Host <> nil) and (Host.FActive <> nil);
  if Result then
    Host.FDialog.HandleKey(Key, KeyChar);
end;

constructor TRetroDialog.Create(AOwner: TComponent);
begin
  inherited;
  Visible := False;
  ButtonAccept.OnClick := AcceptClick;
  ButtonCancel.OnClick := CancelClick;
  ButtonAlternative.OnClick := AlternativeClick;
  ButtonClose.OnClick := CancelClick;
  AddButtonIcon(ButtonClose, IconClose, 16);

  FBusyIndicator := TAniIndicator.Create(Self);
  FBusyIndicator.Name := 'LoadingIndicator';
  FBusyIndicator.Parent := CircleBadge;
  FBusyIndicator.Align := TAlignLayout.Client;
  FBusyIndicator.HitTest := False;
  FBusyIndicator.Visible := False;
  FBusyIndicator.Margins.Rect := RectF(-6, -6, 0, 0);

  FReady := True;
end;

procedure TRetroDialog.Configure(const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>;
  const AcceptText, CancelText, AlternativeText: string; const OnAlternative: TProc);
const
  Titles: array[TRetroDialogKind] of string = ('Information', 'Warning', 'Error', 'Confirmation', 'Loading...');
  Symbols: array[TRetroDialogKind] of string = ('i', '!', '!', '?', '');
begin
  FOnResult := OnResult;
  FOnAlternative := OnAlternative;
  FConfirmation := Kind = TRetroDialogKind.Confirmation;
  FLoading := Kind = TRetroDialogKind.Loading;
  FCustomActions := (AcceptText <> '') or (CancelText <> '');
  FBusyIndicator.Visible := FLoading;
  FBusyIndicator.Enabled := FLoading;
  LabelBadge.Visible := not FLoading;
  ButtonAccept.Visible := not FLoading;
  LabelTitle.Text := Translate(Titles[Kind]);
  LabelBadge.Text := Symbols[Kind];
  LabelMessage.Text := Text;
  ButtonClose.Hint := Translate('Close');
  ButtonCancel.Text := Translate('Cancel');
  if FConfirmation then
    ButtonAccept.Text := Translate('Confirm')
  else
    ButtonAccept.Text := Translate('OK');
  if AcceptText <> '' then
    ButtonAccept.Text := Translate(AcceptText);
  if CancelText <> '' then
    ButtonCancel.Text := Translate(CancelText);
  ButtonAlternative.Visible := AlternativeText <> '';
  ButtonAlternative.Text := Translate(AlternativeText);
  ButtonAlternative.TextSettings.WordWrap := True;
  ButtonAccept.TextSettings.WordWrap := FCustomActions;
  ButtonCancel.TextSettings.WordWrap := FCustomActions;
  ButtonCancel.Visible := FConfirmation or FLoading;
  VertScrollBoxMessage.ViewportPosition := TPointF.Zero;
  Arrange;
end;

procedure TRetroDialog.FocusDefault;
begin
  if FConfirmation or FLoading then
    ButtonCancel.SetFocus
  else
    ButtonAccept.SetFocus;
end;

procedure TRetroDialog.AcceptClick(Sender: TObject);
begin
  var Callback := FOnResult;
  if Assigned(Callback) then
    Callback(True);
end;

procedure TRetroDialog.CancelClick(Sender: TObject);
begin
  var Callback := FOnResult;
  if Assigned(Callback) then
    Callback(False);
end;

procedure TRetroDialog.AlternativeClick(Sender: TObject);
begin
  var Callback := FOnAlternative;
  if Assigned(Callback) then Callback();
end;

procedure TRetroDialog.HandleKey(var Key: Word; var KeyChar: WideChar);
begin
  if (Key = vkEscape) {$IFDEF ANDROID} or (Key = vkHardwareBack){$ENDIF} then
    CancelClick(Self)
  else if Key = vkReturn then
  begin
    if ButtonAlternative.Visible and ButtonAlternative.IsFocused then
      AlternativeClick(Self)
    else if FLoading or (FConfirmation and not ButtonAccept.IsFocused) or ButtonClose.IsFocused then
      CancelClick(Self)
    else
      AcceptClick(Self);
  end;

  // Tab is handled by FMX; the rest must never reach game shortcuts.
  if Key <> vkTab then
  begin
    Key := 0;
    KeyChar := #0;
  end;
end;

procedure TRetroDialog.Resize;
begin
  inherited;
  if FReady and not (csLoading in ComponentState) then
    Arrange;
end;

procedure TRetroDialog.Arrange;
begin
  if FArranging then Exit;
  FArranging := True;
  try
    var W := Max(1, Min(560, Width - 32));
    var Padding := Min(24, Max(8, W / 12));
    var TextWidth := Max(1, W - Padding * 2 - 16);
    var TextHeight: Single;

    var Layout := TTextLayoutManager.DefaultTextLayout.Create;
    try
      Layout.BeginUpdate;
      Layout.Font.Assign(LabelMessage.TextSettings.Font);
      Layout.MaxSize := TPointF.Create(TextWidth, 100000);
      Layout.WordWrap := True;
      Layout.Text := LabelMessage.Text;
      Layout.EndUpdate;
      TextHeight := Max(24, Ceil(Layout.TextHeight) + 8);
    finally
      Layout.Free;
    end;

    var ActionHeight: Single := 42;
    if FCustomActions then
      ActionHeight := 56;
    var Stacked := ButtonAlternative.Visible and (W < 480);
    if Stacked then
      ActionHeight := 160;
    var FixedHeight := Padding * 2 + 44 + 16 + 16 + ActionHeight;
    var BodyHeight := Min(TextHeight, Max(0, Height - 32 - FixedHeight));
    var H := FixedHeight + BodyHeight;
    // Center alignment places the card; its rows own all child geometry.
    PanelCard.BeginUpdate;
    try
      PanelCard.Width := W;
      PanelCard.Height := H;
      PanelCard.Padding.Rect := TRectF.Create(Padding, Padding, Padding, Padding);
      VertScrollBoxMessage.Height := BodyHeight;
      LabelMessage.Height := TextHeight;
      var ButtonWidth := Min(148, W - Padding * 2);
      if FConfirmation then
        if FCustomActions then
          if ButtonAlternative.Visible then
            ButtonWidth := Max(1, (W - Padding * 2 - 24) / 3)
          else
            ButtonWidth := Max(1, (W - Padding * 2 - 12) / 2)
        else
          ButtonWidth := Min(ButtonWidth, (W - Padding * 2 - 12) / 2);
      var Actions := TControl(ButtonAccept.Parent);
      Actions.BeginUpdate;
      try
        Actions.Height := ActionHeight;
        ButtonAccept.Height := ActionHeight;
        ButtonCancel.Height := ActionHeight;
        ButtonAccept.Width := ButtonWidth;
        ButtonCancel.Width := ButtonWidth;
        var Buttons: TArray<TButton> := [ButtonAccept, ButtonAlternative, ButtonCancel];
        for var I := 0 to High(Buttons) do
        begin
          var Button := Buttons[I];
          Button.Margins.Left := 0;
          Button.Margins.Top := 0;
          Button.Margins.Bottom := 0;
          if Stacked then
          begin
            Button.Align := TAlignLayout.Top;
            Button.Position.Y := I * 56;
            Button.Height := 48;
            Button.Margins.Right := 0;
            if I < High(Buttons) then Button.Margins.Bottom := 8;
          end
          else
          begin
            Button.Align := TAlignLayout.Right;
            Button.Position.X := I * 200;
            Button.Width := ButtonWidth;
            Button.Height := ActionHeight;
            // Right-aligned controls are ordered from cancel back to accept.
            // Reserve space after the left/middle actions, never at the outer edge.
            if (Button <> ButtonCancel) and ButtonCancel.Visible then
              Button.Margins.Right := 12
            else
              Button.Margins.Right := 0;
          end;
        end;
      finally
        Actions.EndUpdate;
      end;
    finally
      PanelCard.EndUpdate;
    end;
    // TVertScrollBox can retain the previous content width after shrinking.
    VertScrollBoxMessage.Content.BeginUpdate;
    try
      LabelMessage.Width := TextWidth;
      VertScrollBoxMessage.Content.Width := Max(1, W - Padding * 2);
    finally
      VertScrollBoxMessage.Content.EndUpdate;
    end;
    VertScrollBoxMessage.RealignContent;
  finally
    FArranging := False;
    // Centering moves the card while BeginUpdate suppresses invalidation of its
    // old bounds. Repaint the backdrop too, so no previous card pixels remain.
    Repaint;
  end;
end;

constructor TRetroDialogHost.Create(AOwner: TComponent);
begin
  inherited;
  FForm := AOwner as TCustomForm;
  FQueue := TObjectList<TDialogRequest>.Create;
  FBlocked := TList<TControl>.Create;
  FDialog := TRetroDialog.Create(Self);
  FDialog.Parent := FForm;
  FDialog.Align := TAlignLayout.Contents;
end;

destructor TRetroDialogHost.Destroy;
begin
  FOnActivity := nil;
  FDialog.Free;
  FActive.Free;
  FQueue.Free;
  FBlocked.Free;
  inherited;
end;

procedure TRetroDialogHost.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if Operation <> TOperation.opRemove then
    Exit;

  if AComponent = FDialog then
    FDialog := nil;
  if AComponent = FPreviousFocus then
    FPreviousFocus := nil;
  if (FBlocked <> nil) and (AComponent is TControl) then
    FBlocked.Remove(TControl(AComponent));
  if FQueue <> nil then
    for var i := FQueue.Count - 1 downto 0 do
      if FQueue[i].Requester = AComponent then
        FQueue.Delete(i);

  if (FActive <> nil) and (FActive.Requester = AComponent) and
    not (csDestroying in ComponentState) and not (csDestroying in FForm.ComponentState) then
    Complete(False, False);
end;

procedure TRetroDialogHost.BeginModal;
begin
  if FModal then
    Exit;

  FModal := True;
  if (FForm.Focused <> nil) and (FForm.Focused.GetObject is TControl) then
  begin
    FPreviousFocus := TControl(FForm.Focused.GetObject);
    FPreviousFocus.FreeNotification(Self);
  end;

  // Disable only controls that were enabled, preserving their original state.
  for var i := 0 to FForm.ChildrenCount - 1 do
    if (FForm.Children[i] is TControl) and (FForm.Children[i] <> FDialog) then
    begin
      var Control := TControl(FForm.Children[i]);
      if Control.Enabled then
      begin
        FBlocked.Add(Control);
        Control.FreeNotification(Self);
        Control.Enabled := False;
      end;
    end;

  if Assigned(FOnActivity) then
    FOnActivity(Self);
end;

procedure TRetroDialogHost.EndModal;
begin
  FModal := False;
  FDialog.Visible := False;
  FDialog.FBusyIndicator.Enabled := False;
  for var Control in FBlocked do
    Control.Enabled := True;
  FBlocked.Clear;
  if (FPreviousFocus <> nil) and FPreviousFocus.CanFocus and FPreviousFocus.IsVisible and FPreviousFocus.Enabled then
    FPreviousFocus.SetFocus;
  FPreviousFocus := nil;
  if Assigned(FOnActivity) then
    FOnActivity(Self);
end;

procedure TRetroDialogHost.ShowNext;
begin
  if FCompleting or (FActive <> nil) or (csDestroying in FForm.ComponentState) then
    Exit;

  if FQueue.Count = 0 then
  begin
    if FModal then
      EndModal;
    Exit;
  end;

  FActive := FQueue.Extract(FQueue[0]);
  BeginModal;
  FDialog.Configure(FActive.Text, FActive.Kind,
    procedure(Confirmed: Boolean)
    begin
      Complete(Confirmed);
    end, FActive.AcceptText, FActive.CancelText, FActive.AlternativeText,
    procedure
    begin
      Complete(False, True, True);
    end);
  FDialog.Visible := True;
  FDialog.BringToFront;
  FDialog.FocusDefault;
end;

procedure TRetroDialogHost.Complete(Confirmed: Boolean; InvokeCallback, Alternative: Boolean);
begin
  if (FActive = nil) or FCompleting then
    Exit;

  var Callback := FActive.OnResult;
  var AlternativeCallback := FActive.OnAlternative;
  FreeAndNil(FActive);
  FCompleting := True;
  try
    if InvokeCallback then
      if Alternative then
      begin
        if Assigned(AlternativeCallback) then AlternativeCallback();
      end
      else if Assigned(Callback) then
        Callback(Confirmed);
  finally
    FCompleting := False;
    ShowNext;
  end;
end;

procedure TRetroDialogHost.Enqueue(Requester: TComponent; const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>;
  const AcceptText, CancelText, AlternativeText: string; const OnAlternative: TProc);
begin
  if not Assigned(OnResult) then
  begin
    if (FActive <> nil) and (FActive.Text = Text) and (FActive.Kind = Kind) then
      Exit;

    for var Queued in FQueue do
      if (Queued.Text = Text) and (Queued.Kind = Kind) then
        Exit;
  end;

  var Request := TDialogRequest.Create;
  Request.Requester := Requester;
  Request.Text := Text;
  Request.Kind := Kind;
  Request.OnResult := OnResult;
  Request.AcceptText := AcceptText;
  Request.CancelText := CancelText;
  Request.AlternativeText := AlternativeText;
  Request.OnAlternative := OnAlternative;
  if Requester <> nil then
    Requester.FreeNotification(Self);
  FQueue.Add(Request);
  ShowNext;
end;

end.

