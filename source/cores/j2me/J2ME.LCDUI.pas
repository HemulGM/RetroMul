unit J2ME.LCDUI;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Alert.Layout,
  J2ME.Form.Layout, J2ME.Item.Layout;

type
  TJ2MELCDUI = class
  private
    FVM: TJVM;
    FWidth, FHeight, FCurrent: Integer;
    FDirty: Boolean;
    FMenu, FScrollText: Boolean;
    FMenuIndex: Integer;
    FTickerStep: Int64;
    FAlertLayout: TJ2MEAlertLayout;
    FFormLayout: TJ2MEFormLayout;
    FEditorRef, FEditorText, FEditorConstraints, FEditorWidth, FEditorNegative: Integer;
    FEditorLines: TArray<TJ2METextLine>;
    FPostItemChanged: TProc<Integer>;
    FChangeScreen: TProc<Integer>;
    FPostTimeout: TProc<Integer, Integer>;
    FAlertStarted, FAlertQueued, FAlertFired, FPaused: Boolean;
    FAlertStart, FPausedAt: Int64;
    function AlertCommand: Integer;
    function AlertTimeout(Screen: Integer): Integer;
    procedure AlertChanged(O: TJVMObject);
    function AlertInvoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function Commands(Screen: Integer): TArray<Integer>;
    function RightCommand(const Values: TArray<Integer>): Integer;
    function SelectCommand(Screen: Integer): Integer;
    procedure CommandAction(Command, Screen: Integer);
    procedure SendFormCommand(Screen, Command, Item: Integer);
    procedure ItemChanged(Item: Integer; Queue: Boolean);
    function FormKey(Screen, Code: Integer): Boolean;
    function FocusedItem(Screen: Integer): Integer;
    function ChoicePopup(Screen: Integer): Boolean;
    procedure Key(Screen, Code: Integer; Pressed: Boolean);
    function ChoiceInvoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  public
    constructor Create(VM: TJVM; Width, Height: Integer; const ChangeScreen: TProc<Integer>; const PostTimeout: TProc<Integer, Integer>; const PostItemChanged: TProc<Integer>);
    destructor Destroy; override;
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function IsCanvas(Screen: Integer): Boolean;
    function IsAlert(Screen: Integer): Boolean;
    function IsForm(Screen: Integer): Boolean;
    function IsTextBox(Screen: Integer): Boolean;
    procedure FocusItem(Item: Integer);
    procedure ConfigureAlert(Screen, Next: Integer);
    procedure PollAlert(Now: Int64);
    procedure PauseTimer(Paused: Boolean; Now: Int64);
    function IsShown(Screen: Integer): Boolean;
    function Top(Screen: Integer): Integer;
    function ContentHeight(Screen: Integer): Integer;
    function ContentWidth(Screen: Integer): Integer;
    procedure Current(Screen: Integer);
    procedure Invalidate;
    function NeedsRender(Now: Int64): Boolean;
    procedure Render(var Pixels: TArray<UInt32>; const Content: TArray<UInt32>; Now: Int64);
    property CurrentRef: Integer read FCurrent;
  end;

function LCDInt(O: TJVMObject; const Name: string; Default: Integer = 0): Integer;

function LCDRef(O: TJVMObject; const Name: string): Integer;

procedure LCDPut(O: TJVMObject; const Name: string; Value: Integer);

procedure LCDPutRef(O: TJVMObject; const Name: string; Value: Integer);

implementation

uses
  System.Math, Java.Classes, J2ME.Image, J2ME.Font, J2ME.Items, J2ME.Forms,
  J2ME.Text, J2ME.UI.Data, J2ME.DateField;

{$Q-}{$R-}

const
  UI = 'javax/microedition/lcdui/';
  Displayable = UI + 'Displayable';
  CommandClass = UI + 'Command';
  FormClass = UI + 'Form';
  TextBoxClass = UI + 'TextBox';
  GroupClass = UI + 'ChoiceGroup';
  AlertClass = UI + 'Alert';
  AlertTypeClass = UI + 'AlertType';
  ListClass = UI + 'List';
  ChoiceClass = UI + 'Choice';
  TickerClass = UI + 'Ticker';
  CD = 'Ljavax/microedition/lcdui/Command;';
  DD = 'Ljavax/microedition/lcdui/Displayable;';
  ID = 'Ljavax/microedition/lcdui/Image;';
  FD = 'Ljavax/microedition/lcdui/Font;';
  SD = 'Ljava/lang/String;';

function LCDInt(O: TJVMObject; const Name: string; Default: Integer): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsInt
  else
    Result := Default;
end;

function LCDRef(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

procedure LCDPut(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Int(Value));
end;

procedure LCDPutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Ref(Value));
end;

constructor TJ2MELCDUI.Create(VM: TJVM; Width, Height: Integer; const ChangeScreen: TProc<Integer>; const PostTimeout: TProc<Integer, Integer>; const PostItemChanged: TProc<Integer>);
begin
  inherited Create;
  FVM := VM;
  FWidth := Width;
  FHeight := Height;
  FChangeScreen := ChangeScreen;
  FPostTimeout := PostTimeout;
  FPostItemChanged := PostItemChanged;
  FAlertLayout := TJ2MEAlertLayout.Create(VM);
  FFormLayout := TJ2MEFormLayout.Create(VM);
end;

destructor TJ2MELCDUI.Destroy;
begin
  FFormLayout.Free;
  FAlertLayout.Free;
  inherited;
end;

procedure TJ2MELCDUI.Install;
var
  B: TJavaClassBuilder;

  procedure Native(const Name, D: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, D).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure ChoiceMethods(AbstractOnly: Boolean);
  var
    Flags: Word;
  begin
    Flags := JVM_ACC_PUBLIC;
    if AbstractOnly then
      Flags := Flags or JVM_ACC_ABSTRACT;
    Native('append', '(' + SD + ID + ')I', Flags);
    Native('insert', '(I' + SD + ID + ')V', Flags);
    Native('set', '(I' + SD + ID + ')V', Flags);
    Native('delete', '(I)V', Flags);
    Native('deleteAll', '()V', Flags);
    Native('size', '()I', Flags);
    Native('getString', '(I)' + SD, Flags);
    Native('getImage', '(I)' + ID, Flags);
    Native('isSelected', '(I)Z', Flags);
    Native('getSelectedIndex', '()I', Flags);
    Native('getSelectedFlags', '([Z)I', Flags);
    Native('setSelectedIndex', '(IZ)V', Flags);
    Native('setSelectedFlags', '([Z)V', Flags);
    Native('setFitPolicy', '(I)V', Flags);
    Native('getFitPolicy', '()I', Flags);
    Native('setFont', '(I' + FD + ')V', Flags);
    Native('getFont', '(I)' + FD, Flags);
    if AbstractOnly then
      for var M in B.JavaClass.Methods do
        M.Access := (M.Access and not JVM_ACC_NATIVE) or JVM_ACC_ABSTRACT;
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(CommandClass, 'java/lang/Object');
    for var I := 1 to 8 do
    begin
      var Name := '';
      case I of
        1:
          Name := 'SCREEN';
        2:
          Name := 'BACK';
        3:
          Name := 'CANCEL';
        4:
          Name := 'OK';
        5:
          Name := 'HELP';
        6:
          Name := 'STOP';
        7:
          Name := 'EXIT';
        8:
          Name := 'ITEM';
      end;
      Constant(Name, I);
    end;
    Native('<init>', '(' + SD + 'II)V');
    Native('<init>', '(' + SD + SD + 'II)V');
    Native('getLabel', '()' + SD);
    Native('getLongLabel', '()' + SD);
    Native('getCommandType', '()I');
    Native('getPriority', '()I');
    Done;
    B := TJavaClassBuilder.Create(UI + 'CommandListener', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    B.JavaClass.AddNative('commandAction', '(' + CD + DD + ')V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Done;
    B := TJavaClassBuilder.Create(TickerClass, 'java/lang/Object');
    Native('<init>', '(' + SD + ')V');
    Native('getString', '()' + SD);
    Native('setString', '(' + SD + ')V');
    Done;
    B := TJavaClassBuilder.Create(Displayable, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    Native('<init>', '()V', JVM_ACC_PROTECTED);
    Native('getWidth', '()I');
    Native('getHeight', '()I');
    Native('isShown', '()Z');
    Native('getTitle', '()' + SD);
    Native('setTitle', '(' + SD + ')V');
    Native('getTicker', '()Ljavax/microedition/lcdui/Ticker;');
    Native('setTicker', '(Ljavax/microedition/lcdui/Ticker;)V');
    Native('addCommand', '(' + CD + ')V');
    Native('removeCommand', '(' + CD + ')V');
    Native('setCommandListener', '(Ljavax/microedition/lcdui/CommandListener;)V');
    Native('sizeChanged', '(II)V', JVM_ACC_PROTECTED);
    Native('$key', '(IZ)V', JVM_ACC_PRIVATE);
    Native('$text', '(Ljava/lang/String;)V', JVM_ACC_PRIVATE);
    Done;
    B := TJavaClassBuilder.Create(UI + 'Screen', Displayable, JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    Native('<init>', '()V', JVM_ACC_PROTECTED);
    Done;
    InstallJ2MEItems(FVM);
    InstallJ2METext(FVM);
    InstallJ2MEForms(FVM);
    InstallJ2MEDateField(FVM);
    B := TJavaClassBuilder.Create(AlertTypeClass, 'java/lang/Object');
    Native('<init>', '()V', JVM_ACC_PROTECTED);
    Native('playSound', '(Ljavax/microedition/lcdui/Display;)Z');
    for var Name in ['INFO', 'WARNING', 'ERROR', 'ALARM', 'CONFIRMATION'] do
      B.Field(Name, 'Ljavax/microedition/lcdui/AlertType;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    Done;
    var Kind := 0;
    for var Field in FVM.LoadClass(AlertTypeClass).Fields do
    begin
      Inc(Kind);
      var Ref := FVM.NewObject(AlertTypeClass);
      LCDPut(FVM.GetObject(Ref), 'alertType', Kind);
      Field.Value := TJVMValue.Ref(Ref);
    end;
    B := TJavaClassBuilder.Create(AlertClass, UI + 'Screen');
    Constant('FOREVER', -2);
    B.Field('DISMISS_COMMAND', CD, JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    Native('<init>', '(' + SD + ')V');
    Native('<init>', '(' + SD + SD + ID + 'Ljavax/microedition/lcdui/AlertType;)V');
    for var Name in ['getDefaultTimeout', 'getTimeout'] do
      Native(Name, '()I');
    Native('setTimeout', '(I)V');
    Native('getString', '()' + SD);
    Native('setString', '(' + SD + ')V');
    Native('getImage', '()' + ID);
    Native('setImage', '(' + ID + ')V');
    Native('getType', '()Ljavax/microedition/lcdui/AlertType;');
    Native('setType', '(Ljavax/microedition/lcdui/AlertType;)V');
    Native('getIndicator', '()Ljavax/microedition/lcdui/Gauge;');
    Native('setIndicator', '(Ljavax/microedition/lcdui/Gauge;)V');
    for var Name in ['addCommand', 'removeCommand'] do
      Native(Name, '(' + CD + ')V');
    Native('setCommandListener', '(Ljavax/microedition/lcdui/CommandListener;)V');
    Native('$timeout', '(I)V', JVM_ACC_PRIVATE);
    Done;
    var Dismiss := FVM.NewObject(CommandClass);
    LCDPutRef(FVM.GetObject(Dismiss), 'label', FVM.NewString(''));
    LCDPut(FVM.GetObject(Dismiss), 'type', 4);
    FVM.LoadClass(AlertClass).Fields.Last.Value := TJVMValue.Ref(Dismiss);
    B := TJavaClassBuilder.Create(ChoiceClass, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    Constant('EXCLUSIVE', 1);
    Constant('MULTIPLE', 2);
    Constant('IMPLICIT', 3);
    Constant('POPUP', 4);
    Constant('TEXT_WRAP_DEFAULT', 0);
    Constant('TEXT_WRAP_ON', 1);
    Constant('TEXT_WRAP_OFF', 2);
    ChoiceMethods(True);
    Done;
    B := TJavaClassBuilder.Create(ListClass, UI + 'Screen');
    B.JavaClass.Interfaces := [ChoiceClass];
    B.Field('SELECT_COMMAND', CD, JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    Native('<init>', '(' + SD + 'I)V');
    Native('<init>', '(' + SD + 'I[' + SD + '[' + ID + ')V');
    Native('setSelectCommand', '(' + CD + ')V');
    ChoiceMethods(False);
    Done;
    B := TJavaClassBuilder.Create(GroupClass, UI + 'Item');
    B.JavaClass.Interfaces := [ChoiceClass];
    Native('<init>', '(' + SD + 'I)V');
    Native('<init>', '(' + SD + 'I[' + SD + '[' + ID + ')V');
    ChoiceMethods(False);
    Done;
    var Select := FVM.NewObject(CommandClass);
    var O := FVM.GetObject(Select);
    LCDPutRef(O, 'label', FVM.NewString(''));
    LCDPut(O, 'type', 1);
    FVM.LoadClass(ListClass).Fields.Last.Value := TJVMValue.Ref(Select);
  finally
    B.Free;
  end;
end;

function TJ2MELCDUI.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = CommandClass) or (Owner = Displayable) or (Owner = TickerClass) or (Owner = UI + 'Screen') or (Owner = ListClass) or (Owner = AlertClass) or (Owner = AlertTypeClass) or (Owner = UI + 'Item') or (Owner = UI + 'Gauge') or (Owner = FormClass) or (Owner = GroupClass) or
    (Owner = UI + 'DateField') or (Owner = TextBoxClass) or (Owner = UI + 'TextField') or (Owner = UI + 'StringItem') or (Owner = UI + 'ImageItem') or (Owner = UI + 'Spacer');
end;

function TJ2MELCDUI.IsCanvas(Screen: Integer): Boolean;
begin
  Result := (Screen <> 0) and FVM.IsAssignable(FVM.GetObject(Screen).ClassName, UI + 'Canvas');
end;

function TJ2MELCDUI.IsAlert(Screen: Integer): Boolean;
begin
  Result := (Screen <> 0) and FVM.IsAssignable(FVM.GetObject(Screen).ClassName, AlertClass);
end;

function TJ2MELCDUI.AlertCommand: Integer;
begin
  for var Field in FVM.LoadClass(AlertClass).Fields do
    if Field.Name = 'DISMISS_COMMAND' then
      Exit(Field.Value.AsRef);
  raise EJVMError.Create('Alert command missing');
end;

procedure TJ2MELCDUI.AlertChanged(O: TJVMObject);
begin
  LCDPut(O, 'alertGeneration', LCDInt(O, 'alertGeneration') + 1);
  if (FCurrent <> 0) and (FVM.GetObject(FCurrent) = O) then
  begin
    FAlertStarted := False;
    FAlertQueued := False;
    FAlertFired := False;
  end;
  FDirty := True;
end;

procedure TJ2MELCDUI.ConfigureAlert(Screen, Next: Integer);
begin
  var O := FVM.GetObject(Screen);
  LCDPutRef(O, 'alertNext', Next);
  AlertChanged(O);
end;

function TJ2MELCDUI.AlertTimeout(Screen: Integer): Integer;
begin
  var O := FVM.GetObject(Screen);
  Result := LCDInt(O, 'timeout', 2000);
  var Cmds := LCDRef(O, 'commands');
  if (Cmds <> 0) and (Length(FVM.GetObject(Cmds).Elements) > 1) then
    Exit(-2);
  FAlertLayout.Update(Screen, FWidth, ContentHeight(Screen));
  if FAlertLayout.TotalHeight > FAlertLayout.BodyHeight then
    Result := -2;
  if Screen <> FCurrent then
    FAlertLayout.Clear;
end;

procedure TJ2MELCDUI.PauseTimer(Paused: Boolean; Now: Int64);
begin
  if FPaused = Paused then
    Exit;
  if Paused then
    FPausedAt := Now
  else if FAlertStarted and (Now >= FPausedAt) then
  begin
    var Delta := Now - FPausedAt;
    if Delta > High(Int64) - FAlertStart then
      FAlertStart := Now
    else
      Inc(FAlertStart, Delta);
  end;
  FPaused := Paused;
end;

procedure TJ2MELCDUI.PollAlert(Now: Int64);
begin
  if FPaused or not FAlertStarted or FAlertQueued or FAlertFired or not IsAlert(FCurrent) then
    Exit;
  var Timeout := AlertTimeout(FCurrent);
  if (Timeout > 0) and (Now >= FAlertStart) and (Now - FAlertStart >= Timeout) then
  begin
    FAlertQueued := True;
    FPostTimeout(FCurrent, LCDInt(FVM.GetObject(FCurrent), 'alertGeneration'));
  end;
end;

function TJ2MELCDUI.IsForm(Screen: Integer): Boolean;
begin
  Result := (Screen <> 0) and FVM.IsAssignable(FVM.GetObject(Screen).ClassName, FormClass);
end;

function TJ2MELCDUI.IsTextBox(Screen: Integer): Boolean;
begin
  Result := (Screen <> 0) and FVM.IsAssignable(FVM.GetObject(Screen).ClassName, TextBoxClass);
end;

function TJ2MELCDUI.FocusedItem(Screen: Integer): Integer;
begin
  Result := 0;
  if IsForm(Screen) then
    Result := J2MEFormFocused(FVM, Screen);
end;

procedure TJ2MELCDUI.FocusItem(Item: Integer);
begin
  var Owner := LCDRef(FVM.GetObject(Item), 'owner');
  if (Owner = 0) or not IsForm(Owner) then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Item is not in a Form');
  FChangeScreen(Owner);
  J2MEFormFocus(FVM, Owner, Item);
  LCDPutRef(FVM.GetObject(Owner), 'ensureItem', Item);
  FDirty := True;
end;

procedure TJ2MELCDUI.ItemChanged(Item: Integer; Queue: Boolean);
begin
  var Owner := LCDRef(FVM.GetObject(Item), 'owner');
  if (Owner = 0) or not IsForm(Owner) then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Item is not in a Form');
  J2MEFormMarkChanged(FVM, Owner, Item);
  if Queue then
    FPostItemChanged(Owner)
  else
    FVM.InvokeGuest(FVM.LoadClass(FormClass).FindMethod('$drain', '()V'), [TJVMValue.Ref(Owner)]);
end;

function TJ2MELCDUI.ChoicePopup(Screen: Integer): Boolean;
begin
  var Ref := FocusedItem(Screen);
  Result := (Ref <> 0) and (LCDInt(FVM.GetObject(Ref), 'itemKind') = 6) and (LCDInt(FVM.GetObject(Ref), 'expanded') <> 0);
end;

function TJ2MELCDUI.IsShown(Screen: Integer): Boolean;
begin
  Result := (Screen <> 0) and (Screen = FCurrent) and not FMenu;
end;

function TJ2MELCDUI.Top(Screen: Integer): Integer;
begin
  Result := 0;
  if Screen = 0 then
    Exit;
  var O := FVM.GetObject(Screen);
  if IsCanvas(Screen) and (LCDInt(O, 'full') <> 0) then
    Exit;
  if LCDRef(O, 'title') <> 0 then
    Inc(Result, 20);
  if LCDRef(O, 'ticker') <> 0 then
    Inc(Result, 16);
  Result := Min(Result, Max(0, FHeight - 1));
end;

function TJ2MELCDUI.ContentWidth(Screen: Integer): Integer;
begin
  Result := FWidth;
  if IsForm(Screen) then
    Result := Max(1, FWidth - 12);
end;

function TJ2MELCDUI.ContentHeight(Screen: Integer): Integer;
begin
  Result := FHeight;
  if Screen = 0 then
    Exit;
  var O := FVM.GetObject(Screen);
  if IsCanvas(Screen) and (LCDInt(O, 'full') <> 0) then
    Exit;
  // Geometry is queried by drawing methods too; it must not sort commands.
  var Footer := not IsCanvas(Screen);
  var CommandRefs := LCDRef(O, 'commands');
  if (CommandRefs <> 0) and (Length(FVM.GetObject(CommandRefs).Elements) > 0) then
    Footer := True;
  Result := Max(1, FHeight - Top(Screen) - Ord(Footer) * Min(20, FHeight - 1));
end;

procedure TJ2MELCDUI.Current(Screen: Integer);
begin
  if IsAlert(FCurrent) then
  begin
    var Old := FVM.GetObject(FCurrent);
    LCDPutRef(Old, 'alertNext', 0);
    AlertChanged(Old);
  end;
  if IsTextBox(FCurrent) then
    LCDPut(FVM.GetObject(FCurrent), 'editing', 0);
  FCurrent := Screen;
  FMenu := False;
  FMenuIndex := 0;
  FDirty := True;
  FAlertStarted := False;
  FAlertQueued := False;
  FAlertFired := False;
  FAlertLayout.Clear;
  FFormLayout.Clear;
  FEditorRef := 0;
  FEditorLines := nil;
  if IsAlert(Screen) then
  begin
    var O := FVM.GetObject(Screen);
    LCDPut(O, 'scroll', 0);
    AlertChanged(O);
  end;
  if IsTextBox(Screen) then
    J2METextBegin(FVM, FVM.GetObject(Screen));
end;

procedure TJ2MELCDUI.Invalidate;
begin
  FDirty := True;
end;

function TJ2MELCDUI.NeedsRender(Now: Int64): Boolean;
begin
  Result := FDirty;
  if FCurrent = 0 then
    Exit(False);
  if FPaused then
    Exit;
  if (((LCDRef(FVM.GetObject(FCurrent), 'ticker') <> 0) and (Top(FCurrent) > 0)) or FScrollText) and (Now div 50 <> FTickerStep) then
    Result := True;
end;

function TJ2MELCDUI.SelectCommand(Screen: Integer): Integer;
begin
  Result := 0;
  var O := FVM.GetObject(Screen);
  if not FVM.IsAssignable(O.ClassName, ListClass) or (LCDInt(O, 'choiceType') <> 3) or (LCDInt(O, 'selectDisabled') <> 0) then
    Exit;
  Result := LCDRef(O, 'select');
  if Result <> 0 then
    Exit;
  for var F in FVM.LoadClass(ListClass).Fields do
    if F.Name = 'SELECT_COMMAND' then
      Exit(F.Value.AsRef);
end;

function TJ2MELCDUI.Commands(Screen: Integer): TArray<Integer>;
begin
  Result := nil;
  var Ref := LCDRef(FVM.GetObject(Screen), 'commands');
  if Ref <> 0 then
    for var V in FVM.GetObject(Ref).Elements do
    begin
      var N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := V.AsRef;
    end;
  var Item := FocusedItem(Screen);
  if Item <> 0 then
  begin
    var Refs := LCDRef(FVM.GetObject(Item), 'itemCommands');
    if Refs <> 0 then
      for var Value in FVM.GetObject(Refs).Elements do
      begin
        var Found := False;
        for var Existing in Result do
          if Existing = Value.AsRef then
            Found := True;
        if not Found then
        begin
          var N := Length(Result);
          SetLength(Result, N + 1);
          Result[N] := Value.AsRef;
        end;
      end;
  end;
  if IsAlert(Screen) and (Length(Result) = 0) then
    Result := [AlertCommand];
  var Select := SelectCommand(Screen);
  var Rows := LCDRef(FVM.GetObject(Screen), 'rows');
  if (Select <> 0) and (Rows <> 0) and (Length(FVM.GetObject(Rows).Elements) = 0) then
  begin
    for var I := High(Result) downto 0 do
      if Result[I] = Select then
      begin
        for var J := I to High(Result) - 1 do
          Result[J] := Result[J + 1];
        SetLength(Result, Length(Result) - 1);
      end;
    Select := 0;
  end;
  if Select <> 0 then
  begin
    var Found := False;
    for var R in Result do
      if R = Select then
        Found := True;
    if not Found then
    begin
      var N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Select;
    end;
  end;
  // Stable priority order; comparisons avoid overflow at MinInt/MaxInt.
  for var I := 1 to High(Result) do
  begin
    var Value := Result[I];
    var J := I;
    while (J > 0) and (LCDInt(FVM.GetObject(Result[J - 1]), 'priority') > LCDInt(FVM.GetObject(Value), 'priority')) do
    begin
      Result[J] := Result[J - 1];
      Dec(J);
    end;
    Result[J] := Value;
  end;
end;

function TJ2MELCDUI.RightCommand(const Values: TArray<Integer>): Integer;
begin
  Result := 0;
  for var R in Values do
    if LCDInt(FVM.GetObject(R), 'type') in [2, 3, 6, 7] then
      Exit(R);
end;

procedure TJ2MELCDUI.CommandAction(Command, Screen: Integer);
begin
  if Command = SelectCommand(Screen) then
  begin
    var Rows := LCDRef(FVM.GetObject(Screen), 'rows');
    if (Rows <> 0) and (Length(FVM.GetObject(Rows).Elements) = 0) then
      Exit;
  end;
  if Command = 0 then
    Exit;
  if IsForm(Screen) then
  begin
    var Item := FocusedItem(Screen);
    var Target := 0;
    if Item <> 0 then
    begin
      var Refs := LCDRef(FVM.GetObject(Item), 'itemCommands');
      if Refs <> 0 then
        for var Value in FVM.GetObject(Refs).Elements do
          if Value.AsRef = Command then
            Target := Item;
    end;
    FVM.InvokeGuest(FVM.LoadClass(FormClass).FindMethod('$command', '(' + CD + 'Ljavax/microedition/lcdui/Item;)V'),
      [TJVMValue.Ref(Screen), TJVMValue.Ref(Command), TJVMValue.Ref(Target)]);
    Exit;
  end;
  var Listener := LCDRef(FVM.GetObject(Screen), 'listener');
  if IsAlert(Screen) then
  begin
    FAlertFired := True;
    FAlertQueued := False;
  end;
  if Listener = 0 then
  begin
    if IsAlert(Screen) then
      FChangeScreen(LCDRef(FVM.GetObject(Screen), 'alertNext'));
    Exit;
  end;
  var Method := FVM.ResolveVirtualMethod(Listener, FVM.LoadClass(UI + 'CommandListener').FindMethod('commandAction', '(' + CD + DD + ')V'));
  FVM.InvokeGuest(Method, [TJVMValue.Ref(Listener), TJVMValue.Ref(Command), TJVMValue.Ref(Screen)]);
end;

procedure TJ2MELCDUI.SendFormCommand(Screen, Command, Item: Integer);
begin
  if Screen <> FCurrent then
    Exit;
  var Owner := FVM.GetObject(Screen);
  var Refs := LCDRef(Owner, 'commands');
  var Desc := '(' + CD + DD + ')V';
  var API := UI + 'CommandListener';
  var Listener := LCDRef(Owner, 'listener');
  if Item <> 0 then
  begin
    Owner := FVM.GetObject(Item);
    if LCDRef(Owner, 'owner') <> Screen then
      Exit;
    Refs := LCDRef(Owner, 'itemCommands');
    Listener := LCDRef(Owner, 'itemListener');
    Desc := '(' + CD + 'Ljavax/microedition/lcdui/Item;)V';
    API := UI + 'ItemCommandListener';
  end;
  if (Refs = 0) or (Listener = 0) then
    Exit;
  var Found := False;
  for var Value in FVM.GetObject(Refs).Elements do
    if Value.AsRef = Command then
      Found := True;
  if not Found then
    Exit;
  var Receiver := Screen;
  if Item <> 0 then
    Receiver := Item;
  FVM.InvokeGuest(FVM.ResolveVirtualMethod(Listener, FVM.LoadClass(API).FindMethod('commandAction', Desc)),
    [TJVMValue.Ref(Listener), TJVMValue.Ref(Command), TJVMValue.Ref(Receiver)]);
end;

function TJ2MELCDUI.FormKey(Screen, Code: Integer): Boolean;
begin
  Result := True;
  if not IsForm(Screen) then
    Exit(False);
  var Form := FVM.GetObject(Screen);
  var Item := FocusedItem(Screen);
  var Values := J2MEFormItems(FVM, Screen);
  var O: TJVMObject := nil;
  var Kind := 0;
  if Item <> 0 then
  begin
    O := FVM.GetObject(Item);
    Kind := LCDInt(O, 'itemKind');
  end;
  var Popup := (Kind = 6) and (LCDInt(O, 'expanded') <> 0);
  if Popup then
  begin
    var Rows := FVM.GetObject(LCDRef(O, 'rows'));
    var Count := Length(Rows.Elements);
    var Focus := EnsureRange(LCDInt(O, 'focus'), 0, Max(0, Count - 1));
    if Code = -7 then
      LCDPut(O, 'expanded', 0)
    else if (Code = -1) or (Code = 50) then
      Focus := Max(0, Focus - 1)
    else if (Code = -2) or (Code = 56) then
      Focus := Min(Max(0, Count - 1), Focus + 1)
    else if (Code = -5) or (Code = 53) or (Code = -6) then
    begin
      var Changed := False;
      for var I := 0 to Count - 1 do
      begin
        var Row := FVM.GetObject(Rows.Elements[I].AsRef);
        if LCDInt(Row, 'selected') <> Ord(I = Focus) then
          Changed := True;
        LCDPut(Row, 'selected', Ord(I = Focus));
      end;
      LCDPut(O, 'expanded', 0);
      if Changed then
        ItemChanged(Item, False);
    end;
    LCDPut(O, 'focus', Focus);
    LCDPut(Form, 'ensureFocus', 1);
    UIInvalidateOwner(FVM, O);
    FDirty := True;
    Exit;
  end;
  if Kind = 7 then
  begin
    var Default := LCDRef(O, 'itemDefault');
    if (Code = -5) and (Default <> 0) then
    begin
      CommandAction(Default, Screen);
      Exit;
    end;
    if J2MEDateFieldKey(FVM, Item, Code) then
    begin
      LCDPut(Form, 'ensureFocus', 1);
      FDirty := True;
      Exit;
    end;
  end;
  var Direction := 0;
  if (Code = -1) or ((Code = 50) and (Kind <> 5)) then
    Direction := -1;
  if (Code = -2) or ((Code = 56) and (Kind <> 5)) or (Code = -1003) then
    Direction := 1;
  if Direction <> 0 then
  begin
    if (Kind = 6) and (LCDInt(O, 'choiceType') <> 4) and (Code <> -1003) then
    begin
      var Rows := FVM.GetObject(LCDRef(O, 'rows'));
      var Focus := LCDInt(O, 'focus');
      if (Focus + Direction >= 0) and (Focus + Direction < Length(Rows.Elements)) then
      begin
        LCDPut(O, 'focus', Focus + Direction);
        LCDPut(Form, 'ensureFocus', 1);
        FDirty := True;
        Exit;
      end;
    end;
    var H := ContentHeight(Screen);
    FFormLayout.Update(Screen, Max(1, FWidth - 12), H);
    var Index := FFormLayout.Find(Item);
    var Scroll := LCDInt(Form, 'scroll');
    if (Index >= 0) and (Code <> -1003) then
    begin
      var Box := FFormLayout.Boxes[Index];
      var Last := Integer(Min(Int64(MaxInt), Int64(Box.Y) + Box.Height));
      if ((Direction > 0) and (Last > Scroll + H) and (Box.Height > H)) or ((Direction < 0) and (Box.Y < Scroll)) then
      begin
        var Next := EnsureRange(Int64(Scroll) + Direction * 18, Int64(0), Int64(Max(0, FFormLayout.TotalHeight - H)));
        LCDPut(Form, 'scroll', Integer(Next));
        LCDPut(Form, 'ensureFocus', 0);
        FDirty := True;
        Exit;
      end;
    end;
    var Focus := LCDInt(Form, 'focus', -1);
    var Next := Focus + Direction;
    if Focus < 0 then
    begin
      Next := 0;
      if Direction < 0 then
        Next := Length(Values.Elements) - 1;
    end;
    while (Next >= 0) and (Next < Length(Values.Elements)) do
    begin
      if J2MEItemFocusable(FVM, Values.Elements[Next].AsRef) then
      begin
        J2MEFormFocus(FVM, Screen, Values.Elements[Next].AsRef);
        LCDPutRef(Form, 'ensureItem', 0);
        FDirty := True;
        Exit;
      end;
      Inc(Next, Direction);
    end;
    LCDPut(Form, 'scroll', Integer(EnsureRange(Int64(Scroll) + Direction * 18, Int64(0), Int64(Max(0, FFormLayout.TotalHeight - H)))));
    LCDPut(Form, 'ensureFocus', 0);
    FDirty := True;
    Exit;
  end;
  if Kind = 5 then
  begin
    var Default := LCDRef(O, 'itemDefault');
    if (Code = -5) and (Default <> 0) then
    begin
      CommandAction(Default, Screen);
      Exit;
    end;
    var OldNegative := LCDInt(O, 'negativePending');
    var Changed: Boolean;
    if J2METextKey(FVM, O, Code, FVM.Host.MonotonicMillis, Changed) then
    begin
      FDirty := True;
      if OldNegative <> LCDInt(O, 'negativePending') then
        UIInvalidateOwner(FVM, O);
      if Changed then
      begin
        UIInvalidateOwner(FVM, O);
        LCDPut(Form, 'ensureFocus', 1);
        ItemChanged(Item, False);
      end;
    end;
    Exit;
  end;
  if (Kind = 4) and (LCDInt(O, 'interactive') <> 0) and ((Code = -3) or (Code = -4) or (Code = 52) or (Code = 54)) then
  begin
    var Value := LCDInt(O, 'value');
    var Delta := -1;
    if (Code = -4) or (Code = 54) then
      Delta := 1;
    var New := Integer(EnsureRange(Int64(Value) + Delta, Int64(0), Int64(LCDInt(O, 'maximum'))));
    if New <> Value then
    begin
      LCDPut(O, 'value', New);
      FDirty := True;
      ItemChanged(Item, False);
    end;
    Exit;
  end;
  if Kind = 6 then
  begin
    var Rows := FVM.GetObject(LCDRef(O, 'rows'));
    var Count := Length(Rows.Elements);
    if Count = 0 then
      Exit;
    var Focus := EnsureRange(LCDInt(O, 'focus'), 0, Count - 1);
    var Select := False;
    if (Code = -5) or (Code = 53) then
    begin
      if LCDInt(O, 'choiceType') = 4 then
      begin
        LCDPut(O, 'expanded', 1);
        UIInvalidateOwner(FVM, O);
        FDirty := True;
        Exit;
      end;
      Select := True;
    end
    else if (LCDInt(O, 'choiceType') = 4) and ((Code = -3) or (Code = -4)) then
    begin
      var Delta := -1;
      if Code = -4 then
        Delta := 1;
      Focus := EnsureRange(Focus + Delta, 0, Count - 1);
      Select := True;
    end;
    if Select then
    begin
      var Changed := False;
      for var I := 0 to Count - 1 do
      begin
        var Row := FVM.GetObject(Rows.Elements[I].AsRef);
        var Value := Ord(I = Focus);
        if LCDInt(O, 'choiceType') = 2 then
        begin
          Value := LCDInt(Row, 'selected');
          if I = Focus then
            Value := 1 - Value;
        end;
        if Value <> LCDInt(Row, 'selected') then
          Changed := True;
        LCDPut(Row, 'selected', Value);
      end;
      LCDPut(O, 'focus', Focus);
      FDirty := True;
      if Changed then
        ItemChanged(Item, False);
    end;
    Exit;
  end;
  if (Code = -5) or (Code = 53) then
  begin
    var Default := 0;
    if O <> nil then
      Default := LCDRef(O, 'itemDefault');
    if Default <> 0 then
      CommandAction(Default, Screen)
    else
    begin
      var Commands := Self.Commands(Screen);
      if Length(Commands) = 1 then
        CommandAction(Commands[0], Screen)
      else if Length(Commands) > 1 then
      begin
        FMenu := True;
        FMenuIndex := 0;
        FDirty := True;
      end;
    end;
  end;
end;

procedure TJ2MELCDUI.Key(Screen, Code: Integer; Pressed: Boolean);
begin
  if Screen <> FCurrent then
    Exit;
  var O := FVM.GetObject(Screen);
  var Values := Commands(Screen);
  if ChoicePopup(Screen) and Pressed and FormKey(Screen, Code) then
    Exit;
  var Right := RightCommand(Values);
  var Left: TArray<Integer>;
  for var R in Values do
    if R <> Right then
    begin
      var N := Length(Left);
      SetLength(Left, N + 1);
      Left[N] := R;
    end;
  if FMenu then
  begin
    if not Pressed then
      Exit;
    if (Code = -1) or (Code = 50) then
      FMenuIndex := Max(0, FMenuIndex - 1)
    else if (Code = -2) or (Code = 56) then
      FMenuIndex := Min(High(Values), FMenuIndex + 1)
    else if Code = -7 then
      FMenu := False
    else if (Code = -5) or (Code = 53) or (Code = -6) then
    begin
      FMenu := False;
      FDirty := True;
      if (FMenuIndex >= 0) and (FMenuIndex < Length(Values)) then
        CommandAction(Values[FMenuIndex], Screen);
      Exit;
    end;
    FDirty := True;
    Exit;
  end;
  // Normal-mode softkeys stay reserved even when the command list is empty.
  var Full := IsCanvas(Screen) and (LCDInt(O, 'full') <> 0);
  if (Code = -6) or (Code = -7) then
  begin
    if not Pressed then
    begin
      if not Full or ((Length(Values) <> 0) and (LCDRef(O, 'listener') <> 0)) then
        Exit;
    end
    else if Full and (Length(Values) > 0) and (LCDRef(O, 'listener') <> 0) then
    begin
      FMenu := True;
      FMenuIndex := 0;
      FDirty := True;
      Exit;
    end
    else if not Full then
    begin
      if Code = -7 then
        CommandAction(Right, Screen)
      else if Length(Left) = 1 then
        CommandAction(Left[0], Screen)
      else if Length(Left) > 1 then
      begin
        FMenu := True;
        FMenuIndex := 0;
        FDirty := True;
      end;
      Exit;
    end;
  end;
  if IsTextBox(Screen) then
  begin
    if not Pressed then
      Exit;
    var Changed: Boolean;
    if (Code = -1) or (Code = -2) then
    begin
      var Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
      var Lines := J2MEWrapText(J2METextDisplay(FVM, O), Font, Max(1, FWidth - 16));
      var Caret := LCDInt(O, 'caret');
      var Line := J2MECaretLine(Lines, Caret);
      var New := Line - 1;
      if Code = -2 then
        New := Line + 1;
      New := EnsureRange(New, 0, High(Lines));
      LCDPut(O, 'caret', Lines[New].Start + Min(Max(0, Caret - Lines[Line].Start), Lines[New].Count));
      LCDPut(O, 'tapKey', 0);
      FDirty := True;
    end
    else if J2METextKey(FVM, O, Code, FVM.Host.MonotonicMillis, Changed) then
      FDirty := True;
    Exit;
  end;
  if IsForm(Screen) then
  begin
    if Pressed then
      FormKey(Screen, Code);
    Exit;
  end;
  if (Code <= -1000) then
    Exit;
  if IsAlert(Screen) then
  begin
    if not Pressed then
      Exit;
    FAlertLayout.Update(Screen, FWidth, ContentHeight(Screen));
    var Scroll := LCDInt(O, 'scroll');
    if (Code = -1) or (Code = 50) then
      Scroll := Max(0, Scroll - FAlertLayout.LineHeight)
    else if (Code = -2) or (Code = 56) then
      Scroll := Min(Max(0, FAlertLayout.TotalHeight - FAlertLayout.BodyHeight), Scroll + FAlertLayout.LineHeight)
    else if (Code = -5) or (Code = 53) then
    begin
      if Length(Values) = 1 then
        CommandAction(Values[0], Screen)
      else
      begin
        FMenu := True;
        FMenuIndex := 0;
        FDirty := True;
      end;
      Exit;
    end;
    LCDPut(O, 'scroll', Scroll);
    FDirty := True;
    Exit;
  end;
  if FVM.IsAssignable(O.ClassName, ListClass) then
  begin
    if not Pressed then
      Exit;
    var Rows := FVM.GetObject(LCDRef(O, 'rows'));
    var Count := Length(Rows.Elements);
    if Count = 0 then
      Exit;
    var Focus := EnsureRange(LCDInt(O, 'focus'), 0, Count - 1);
    if (Code = -1) or (Code = 50) then
      Focus := Max(0, Focus - 1)
    else if (Code = -2) or (Code = 56) then
      Focus := Min(Count - 1, Focus + 1)
    else if (Code = -5) or (Code = 53) then
    begin
      var Kind := LCDInt(O, 'choiceType');
      if Kind = 2 then
      begin
        var Row := FVM.GetObject(Rows.Elements[Focus].AsRef);
        LCDPut(Row, 'selected', 1 - LCDInt(Row, 'selected'));
      end
      else
        for var I := 0 to Count - 1 do
          LCDPut(FVM.GetObject(Rows.Elements[I].AsRef), 'selected', Ord(I = Focus));
      FDirty := True;
      if Kind = 3 then
        CommandAction(SelectCommand(Screen), Screen);
      Exit;
    end;
    if Focus <> LCDInt(O, 'focus') then
      FVM.GetObject(Rows.Elements[Focus].AsRef).Fields.AddOrSetValue('$ui.scrollStart', TJVMValue.Long(FVM.Host.MonotonicMillis));
    LCDPut(O, 'focus', Focus);
    if LCDInt(O, 'choiceType') = 3 then
      for var I := 0 to Count - 1 do
        LCDPut(FVM.GetObject(Rows.Elements[I].AsRef), 'selected', Ord(I = Focus));
    FDirty := True;
    Exit;
  end;
  if IsCanvas(Screen) then
  begin
    var Name := 'keyReleased';
    if Pressed then
      Name := 'keyPressed';
    FVM.InvokeGuest(FVM.ResolveMethod(FVM.LoadClass(O.ClassName), Name, '(I)V'), [TJVMValue.Ref(Screen), TJVMValue.Int(Code)]);
  end;
end;

function TJ2MELCDUI.AlertInvoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O: TJVMObject;
  N: string;

  procedure SetImage(Ref: Integer);
  begin
    var Snapshot := Ref;
    if Ref <> 0 then
    begin
      var View := J2MEImageView(FVM, Ref);
      if View.Mutable then
      begin
        Snapshot := J2MENewMutableImage(FVM, View.Width, View.Height);
        var Copy := J2MEImageView(FVM, Snapshot);
        Copy.Pixels.Elements := System.Copy(View.Pixels.Elements);
        Copy.Image.Fields[UI + 'Image.$mutable:Z'] := TJVMValue.Int(0);
      end;
    end;
    LCDPutRef(O, 'alertImage', Ref);
    LCDPutRef(O, 'alertSnapshot', Snapshot);
  end;

begin
  Result := Default(TJVMValue);
  O := FVM.GetObject(Args[0].AsRef);
  N := Method.Name;
  if N = '<init>' then
  begin
    LCDPutRef(O, 'title', Args[1].AsRef);
    LCDPut(O, 'timeout', 2000);
    if Length(Args) = 5 then
    begin
      LCDPutRef(O, 'alertText', Args[2].AsRef);
      SetImage(Args[3].AsRef);
      LCDPutRef(O, 'alertType', Args[4].AsRef);
    end;
    Exit;
  end;
  if (N = 'addCommand') or (N = 'removeCommand') or (N = 'setCommandListener') then
    Exit(Invoke(FVM.LoadClass(Displayable).FindMethod(N, Method.Descriptor), Args));
  if N = 'getDefaultTimeout' then
    Exit(TJVMValue.Int(2000));
  if N = 'getTimeout' then
    Exit(TJVMValue.Int(AlertTimeout(Args[0].AsRef)));
  if N = 'getString' then
    Exit(TJVMValue.Ref(LCDRef(O, 'alertText')));
  if N = 'getImage' then
    Exit(TJVMValue.Ref(LCDRef(O, 'alertImage')));
  if N = 'getType' then
    Exit(TJVMValue.Ref(LCDRef(O, 'alertType')));
  if N = 'getIndicator' then
    Exit(TJVMValue.Ref(LCDRef(O, 'indicator')));
  if N = '$timeout' then
  begin
    if (FCurrent <> Args[0].AsRef) or (LCDInt(O, 'alertGeneration') <> Args[1].AsInt) then
      Exit;
    FAlertQueued := False;
    if FPaused or FAlertFired or (AlertTimeout(FCurrent) <= 0) then
      Exit;
    FAlertFired := True;
    var Values := Commands(FCurrent);
    if Length(Values) = 1 then
      CommandAction(Values[0], FCurrent);
    Exit;
  end;
  if N = 'setTimeout' then
  begin
    var Value := Args[1].AsInt;
    if (Value <= 0) and (Value <> -2) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Alert timeout');
    LCDPut(O, 'timeout', Value);
  end
  else if N = 'setString' then
  begin
    LCDPutRef(O, 'alertText', Args[1].AsRef);
    LCDPut(O, 'scroll', 0);
  end
  else if N = 'setType' then
    LCDPutRef(O, 'alertType', Args[1].AsRef)
  else if N = 'setImage' then
  begin
    SetImage(Args[1].AsRef);
    LCDPut(O, 'scroll', 0);
  end
  else if N = 'setIndicator' then
  begin
    var Ref := Args[1].AsRef;
    var Old := LCDRef(O, 'indicator');
    if Old = Ref then
      Exit;
    if Ref <> 0 then
    begin
      var Gauge := FVM.GetObject(Ref);
      var Owner := LCDRef(Gauge, 'owner');
      var Cmds := LCDRef(Gauge, 'itemCommands');
      if (LCDInt(Gauge, 'interactive') <> 0) or ((Owner <> 0) and (Owner <> Args[0].AsRef)) or
        (LCDRef(Gauge, 'label') <> 0) or ((Cmds <> 0) and (Length(FVM.GetObject(Cmds).Elements) <> 0)) or
        (LCDRef(Gauge, 'itemListener') <> 0) or (LCDInt(Gauge, 'layout') <> 0) or
        (LCDInt(Gauge, 'preferredWidth', -1) <> -1) or (LCDInt(Gauge, 'preferredHeight', -1) <> -1) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Alert indicator restrictions');
    end;
    if Old <> 0 then
      LCDPutRef(FVM.GetObject(Old), 'owner', 0);
    if Ref <> 0 then
      LCDPutRef(FVM.GetObject(Ref), 'owner', Args[0].AsRef);
    LCDPutRef(O, 'indicator', Ref);
  end
  else
    raise EJVMUnsupported.Create('Alert method: ' + N);
  AlertChanged(O);
end;

function TJ2MELCDUI.ChoiceInvoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O, Rows, Row: TJVMObject;
  Name: string;
  Count, Index: Integer;

  function Arg(I: Integer): Integer;
  begin
    Result := Args[I].AsInt;
  end;

  procedure Bounds(I: Integer; Inserting: Boolean = False);
  begin
    if (I < 0) or (I >= Count + Ord(Inserting)) then
      FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
  end;

  function ImageSnapshot(R: Integer): Integer;
  begin
    Result := R;
    if R = 0 then
      Exit;
    var View := J2MEImageView(FVM, R);
    if not View.Mutable then
      Exit;
    Result := J2MENewMutableImage(FVM, View.Width, View.Height);
    var Snapshot := J2MEImageView(FVM, Result);
    Snapshot.Pixels.Elements := Copy(View.Pixels.Elements);
    Snapshot.Image.Fields[UI + 'Image.$mutable:Z'] := TJVMValue.Int(0);
  end;

  function NewRow(Text, Image: Integer): Integer;
  begin
    FVM.GetObject(Text);
    Result := FVM.NewObject('java/lang/Object');
    var Item := FVM.GetObject(Result);
    LCDPutRef(Item, 'text', Text);
    LCDPutRef(Item, 'image', ImageSnapshot(Image));
  end;

  procedure Normalize;
  begin
    Count := Length(Rows.Elements);
    LCDPut(O, 'focus', EnsureRange(LCDInt(O, 'focus'), 0, Max(0, Count - 1)));
    if LCDInt(O, 'choiceType') <> 2 then
    begin
      var Found := -1;
      for var I := 0 to Count - 1 do
        if LCDInt(FVM.GetObject(Rows.Elements[I].AsRef), 'selected') <> 0 then
        begin
          if Found < 0 then
            Found := I
          else
            LCDPut(FVM.GetObject(Rows.Elements[I].AsRef), 'selected', 0);
        end;
      if (Found < 0) and (Count > 0) then
      begin
        Found := Min(LCDInt(O, 'focus'), Count - 1);
        LCDPut(FVM.GetObject(Rows.Elements[Found].AsRef), 'selected', 1);
      end;
      if Found >= 0 then
        LCDPut(O, 'focus', Found);
    end;
    FDirty := True;
  end;

begin
  Result := Default(TJVMValue);
  O := FVM.GetObject(Args[0].AsRef);
  Name := Method.Name;
  if Name = '<init>' then
  begin
    var Kind := Arg(2);
    var Group := Method.Owner.Name = GroupClass;
    if (Group and not (Kind in [1, 2, 4])) or (not Group and not (Kind in [1, 2, 3])) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Choice type');
    if Group then
    begin
      UIInitItem(O, Args[1].AsRef);
      LCDPut(O, 'itemKind', 6);
    end
    else
      LCDPutRef(O, 'title', Args[1].AsRef);
    LCDPut(O, 'choiceType', Kind);
    LCDPutRef(O, 'rows', FVM.NewArray('[Ljava/lang/Object;', 0));
    if Length(Args) = 5 then
    begin
      var Strings := FVM.GetObject(Args[3].AsRef);
      var Images: TJVMObject := nil;
      if Args[4].AsRef <> 0 then
      begin
        Images := FVM.GetObject(Args[4].AsRef);
        if Length(Images.Elements) <> Length(Strings.Elements) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Choice arrays');
      end;
      if Length(Strings.Elements) > FVM.MaxArrayLength then
        FVM.RaiseJava('java/lang/OutOfMemoryError', 'Choice capacity');
      var Ref := FVM.NewArray('[Ljava/lang/Object;', Length(Strings.Elements));
      Rows := FVM.GetObject(Ref);
      LCDPutRef(O, 'rows', Ref);
      for var I := 0 to High(Strings.Elements) do
      begin
        var Image := 0;
        if Images <> nil then
          Image := Images.Elements[I].AsRef;
        Rows.Elements[I] := TJVMValue.Ref(NewRow(Strings.Elements[I].AsRef, Image));
      end;
      Normalize;
    end;
    Exit;
  end;
  Rows := FVM.GetObject(LCDRef(O, 'rows'));
  Count := Length(Rows.Elements);
  if Name = 'size' then
    Exit(TJVMValue.Int(Count));
  if Name = 'getFitPolicy' then
    Exit(TJVMValue.Int(LCDInt(O, 'fit')));
  if Name = 'setFitPolicy' then
  begin
    if not (Arg(1) in [0, 1, 2]) then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    LCDPut(O, 'fit', Arg(1));
    FDirty := True;
    Exit;
  end;
  if Name = 'setSelectCommand' then
  begin
    if LCDInt(O, 'choiceType') <> 3 then
      Exit;
    if Args[1].AsRef <> 0 then
    begin
      var DefaultSelect := 0;
      for var F in FVM.LoadClass(ListClass).Fields do
        if F.Name = 'SELECT_COMMAND' then
          DefaultSelect := F.Value.AsRef;
      if Args[1].AsRef <> DefaultSelect then
        Invoke(FVM.LoadClass(Displayable).FindMethod('addCommand', '(' + CD + ')V'), Args);
    end;
    LCDPutRef(O, 'select', Args[1].AsRef);
    LCDPut(O, 'selectDisabled', Ord(Args[1].AsRef = 0));
    FDirty := True;
    Exit;
  end;
  if Name = 'getSelectedIndex' then
  begin
    if LCDInt(O, 'choiceType') = 2 then
      Exit(TJVMValue.Int(-1));
    for var I := 0 to Count - 1 do
      if LCDInt(FVM.GetObject(Rows.Elements[I].AsRef), 'selected') <> 0 then
        Exit(TJVMValue.Int(I));
    Exit(TJVMValue.Int(-1));
  end;
  if (Name = 'setSelectedFlags') or (Name = 'getSelectedFlags') then
  begin
    var Flags := FVM.GetObject(Args[1].AsRef);
    if Length(Flags.Elements) < Count then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Selected flag length');
    var Selected := 0;
    for var I := 0 to Count - 1 do
    begin
      Row := FVM.GetObject(Rows.Elements[I].AsRef);
      if Name = 'setSelectedFlags' then
        LCDPut(Row, 'selected', Ord(Flags.Elements[I].AsInt <> 0));
      if LCDInt(Row, 'selected') <> 0 then
        Inc(Selected);
      if Name = 'getSelectedFlags' then
        Flags.Elements[I] := TJVMValue.Int(Ord(LCDInt(Row, 'selected') <> 0));
    end;
    if Name = 'getSelectedFlags' then
    begin
      for var I := Count to High(Flags.Elements) do
        Flags.Elements[I] := TJVMValue.Int(0);
      Result := TJVMValue.Int(Selected);
    end
    else
    begin
      if (Selected = 0) and (LCDInt(O, 'choiceType') <> 2) then
        LCDPut(O, 'focus', 0);
      Normalize;
    end;
    Exit;
  end;
  if Name = 'deleteAll' then
  begin
    Rows.Elements := nil;
    LCDPut(O, 'focus', 0);
    FDirty := True;
    Exit;
  end;
  if (Name = 'append') or (Name = 'insert') then
  begin
    Index := Count;
    var TextArg := 1;
    if Name = 'insert' then
    begin
      Index := Arg(1);
      TextArg := 2;
    end;
    Bounds(Index, True);
    if (Count >= 65536) or (Count >= FVM.MaxArrayLength) then
      FVM.RaiseJava('java/lang/OutOfMemoryError', 'Choice element limit');
    var R := NewRow(Args[TextArg].AsRef, Args[TextArg + 1].AsRef);
    SetLength(Rows.Elements, Count + 1);
    for var I := Count downto Index + 1 do
      Rows.Elements[I] := Rows.Elements[I - 1];
    Rows.Elements[Index] := TJVMValue.Ref(R);
    Normalize;
    Exit(TJVMValue.Int(Index));
  end;
  Index := Arg(1);
  Bounds(Index);
  Row := FVM.GetObject(Rows.Elements[Index].AsRef);
  if Name = 'delete' then
  begin
    for var I := Index to Count - 2 do
      Rows.Elements[I] := Rows.Elements[I + 1];
    SetLength(Rows.Elements, Count - 1);
    Normalize;
    Exit;
  end;
  if Name = 'set' then
  begin
    FVM.GetObject(Args[2].AsRef);
    var Image := ImageSnapshot(Args[3].AsRef);
    LCDPutRef(Row, 'text', Args[2].AsRef);
    LCDPutRef(Row, 'image', Image);
    FDirty := True;
    Exit;
  end;
  if Name = 'getString' then
    Exit(TJVMValue.Ref(LCDRef(Row, 'text')));
  if Name = 'getImage' then
    Exit(TJVMValue.Ref(LCDRef(Row, 'image')));
  if Name = 'isSelected' then
    Exit(TJVMValue.Int(LCDInt(Row, 'selected')));
  if Name = 'getFont' then
  begin
    var Ref := LCDRef(Row, 'font');
    if Ref = 0 then
      Ref := J2MEGetFont(FVM, 0, 0, 8);
    Exit(TJVMValue.Ref(Ref));
  end;
  if Name = 'setFont' then
  begin
    if Args[2].AsRef <> 0 then
      J2MEFontView(FVM, Args[2].AsRef);
    LCDPutRef(Row, 'font', Args[2].AsRef);
    FDirty := True;
    Exit;
  end;
  if Name = 'setSelectedIndex' then
  begin
    if LCDInt(O, 'choiceType') = 2 then
      LCDPut(Row, 'selected', Ord(Arg(2) <> 0))
    else if Arg(2) <> 0 then
    begin
      for var I := 0 to Count - 1 do
        LCDPut(FVM.GetObject(Rows.Elements[I].AsRef), 'selected', Ord(I = Index));
      LCDPut(O, 'focus', Index);
    end;
    FDirty := True;
    Exit;
  end;
  raise EJVMUnsupported.Create('Choice method ' + Name);
end;

function TJ2MELCDUI.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var C := Method.Owner.Name;
  var N := Method.Name;
  if (C = ListClass) or (C = GroupClass) then
  begin
    Result := ChoiceInvoke(Method, Args);
    if (C = GroupClass) and not N.StartsWith('get') and not N.StartsWith('is') and (N <> 'size') then
      UIInvalidateOwner(FVM, FVM.GetObject(Args[0].AsRef));
    Exit;
  end;
  if (C = FormClass) and (N = '$sendCommand') then
  begin
    SendFormCommand(Args[0].AsRef, Args[1].AsRef, Args[2].AsRef);
    Exit;
  end;
  if (C = FormClass) or (C = UI + 'StringItem') or (C = UI + 'ImageItem') or (C = UI + 'Spacer') then
  begin
    var Changed: Boolean;
    Result := InvokeJ2MEForm(FVM, Method, Args, FWidth, ContentHeight(Args[0].AsRef), Changed);
    if Changed then
    begin
      UIInvalidateOwner(FVM, FVM.GetObject(Args[0].AsRef));
      FDirty := True;
    end;
    Exit;
  end;
  if C = UI + 'DateField' then
  begin
    var Changed: Boolean;
    Result := InvokeJ2MEDateField(FVM, Method, Args, Changed);
    if Changed then
    begin
      var Item := FVM.GetObject(Args[0].AsRef);
      UIInvalidateOwner(FVM, Item);
      FDirty := True;
      if N.StartsWith('$') and (UIRef(Item, 'owner') <> 0) then
      begin
        LCDPut(FVM.GetObject(UIRef(Item, 'owner')), 'ensureFocus', 1);
        ItemChanged(Args[0].AsRef, False);
      end;
    end;
    Exit;
  end;
  if (C = TextBoxClass) or (C = UI + 'TextField') then
  begin
    var Changed: Boolean;
    Result := InvokeJ2METext(FVM, Method, Args, Changed);
    if Changed then
    begin
      UIInvalidateOwner(FVM, FVM.GetObject(Args[0].AsRef));
      FDirty := True;
    end;
    Exit;
  end;
  if (C = UI + 'Item') and (N = 'notifyStateChanged') then
  begin
    ItemChanged(Args[0].AsRef, True);
    Exit;
  end;
  if C = AlertClass then
    Exit(AlertInvoke(Method, Args));
  if (C = UI + 'Item') or (C = UI + 'Gauge') then
  begin
    var Changed: Boolean;
    Result := InvokeJ2MEItem(FVM, Method, Args, FWidth, Changed);
    FDirty := FDirty or Changed;
    if Changed and ((C <> UI + 'Gauge') or ((N <> 'setValue') and (N <> 'setMaxValue'))) then
      UIInvalidateOwner(FVM, FVM.GetObject(Args[0].AsRef));
    Exit;
  end;
  if C = AlertTypeClass then
  begin
    if N = 'playSound' then
    begin
      FVM.GetObject(Args[1].AsRef);
      Exit(TJVMValue.Int(0));
    end;
    if N = '<init>' then
      Exit;
  end;
  var O := FVM.GetObject(Args[0].AsRef);
  if C = CommandClass then
  begin
    if N = '<init>' then
    begin
      FVM.GetObject(Args[1].AsRef);
      var TypeArg := 2;
      if Length(Args) = 5 then
        TypeArg := 3;
      if (Args[TypeArg].AsInt < 1) or (Args[TypeArg].AsInt > 8) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Command type');
      LCDPutRef(O, 'label', Args[1].AsRef);
      if TypeArg = 3 then
        LCDPutRef(O, 'longLabel', Args[2].AsRef);
      LCDPut(O, 'type', Args[TypeArg].AsInt);
      LCDPut(O, 'priority', Args[TypeArg + 1].AsInt);
      Exit;
    end;
    if N = 'getLabel' then
      Exit(TJVMValue.Ref(LCDRef(O, 'label')));
    if N = 'getLongLabel' then
      Exit(TJVMValue.Ref(LCDRef(O, 'longLabel')));
    if N = 'getCommandType' then
      Exit(TJVMValue.Int(LCDInt(O, 'type')));
    if N = 'getPriority' then
      Exit(TJVMValue.Int(LCDInt(O, 'priority')));
  end;
  if C = TickerClass then
  begin
    if N = 'getString' then
      Exit(TJVMValue.Ref(LCDRef(O, 'text')));
    FVM.GetObject(Args[1].AsRef);
    LCDPutRef(O, 'text', Args[1].AsRef);
    LCDPut(O, 'epoch', 0);
    FDirty := True;
    Exit;
  end;
  if (C = Displayable) or (C = UI + 'Screen') then
  begin
    if (N = '<init>') or (N = 'sizeChanged') then
      Exit;
    if N = '$key' then
    begin
      Key(Args[0].AsRef, Args[1].AsInt, Args[2].AsInt <> 0);
      Exit;
    end;
    if N = '$text' then
    begin
      if Args[0].AsRef <> FCurrent then
        Exit;
      var Item := FocusedItem(FCurrent);
      if IsTextBox(FCurrent) then
        Item := FCurrent;
      if Item = 0 then
        Exit;
      var Target := FVM.GetObject(Item);
      if LCDInt(Target, 'itemKind') = 7 then
      begin
        FVM.InvokeGuest(FVM.LoadClass(UI + 'DateField').FindMethod('$input', '(Ljava/lang/String;)V'), [TJVMValue.Ref(Item), Args[1]]);
        Exit;
      end;
      if not IsTextBox(FCurrent) and (LCDInt(Target, 'itemKind') <> 5) then
        Exit;
      if J2METextUserInsert(FVM, Target, FVM.GetObject(Args[1].AsRef).Text) then
      begin
        FDirty := True;
        UIInvalidateOwner(FVM, Target);
        if IsForm(FCurrent) then
          ItemChanged(Item, False);
      end;
      Exit;
    end;
    if N = 'getWidth' then
      Exit(TJVMValue.Int(ContentWidth(Args[0].AsRef)));
    if N = 'getHeight' then
      Exit(TJVMValue.Int(ContentHeight(Args[0].AsRef)));
    if N = 'isShown' then
      Exit(TJVMValue.Int(Ord(IsShown(Args[0].AsRef))));
    if N = 'getTitle' then
      Exit(TJVMValue.Ref(LCDRef(O, 'title')));
    if N = 'getTicker' then
      Exit(TJVMValue.Ref(LCDRef(O, 'ticker')));
    if N = 'setTitle' then
    begin
      LCDPutRef(O, 'title', Args[1].AsRef);
      if IsAlert(Args[0].AsRef) then
        AlertChanged(O);
      FDirty := True;
      Exit;
    end;
    if N = 'setTicker' then
    begin
      LCDPutRef(O, 'ticker', Args[1].AsRef);
      if IsAlert(Args[0].AsRef) then
        AlertChanged(O);
      FDirty := True;
      Exit;
    end;
    if N = 'setCommandListener' then
    begin
      LCDPutRef(O, 'listener', Args[1].AsRef);
      if IsAlert(Args[0].AsRef) then
        AlertChanged(O);
      Exit;
    end;
    if (N = 'addCommand') or (N = 'removeCommand') then
    begin
      var Command := Args[1].AsRef;
      if Command = 0 then
      begin
        if N = 'addCommand' then
          FVM.GetObject(0);
        Exit;
      end;
      if IsAlert(Args[0].AsRef) and (Command = AlertCommand) then
        Exit;
      if (N = 'removeCommand') and (Command = SelectCommand(Args[0].AsRef)) then
      begin
        LCDPutRef(O, 'select', 0);
        LCDPut(O, 'selectDisabled', 1);
        FDirty := True;
      end;
      var Old := LCDRef(O, 'commands');
      var Refs: TArray<TJVMValue>;
      if Old <> 0 then
        Refs := Copy(FVM.GetObject(Old).Elements);
      var Found := -1;
      for var I := 0 to High(Refs) do
        if Refs[I].AsRef = Command then
          Found := I;
      if N = 'addCommand' then
      begin
        if Found >= 0 then
          Exit;
        if Length(Refs) >= 1024 then
          FVM.RaiseJava('java/lang/OutOfMemoryError', 'Command limit');
        var I := Length(Refs);
        SetLength(Refs, I + 1);
        Refs[I] := Args[1];
      end
      else
      begin
        if Found < 0 then
          Exit;
        for var I := Found to Length(Refs) - 2 do
          Refs[I] := Refs[I + 1];
        SetLength(Refs, Length(Refs) - 1);
        if LCDRef(O, 'select') = Command then
        begin
          LCDPutRef(O, 'select', 0);
          LCDPut(O, 'selectDisabled', 1);
        end;
      end;
      var R := FVM.NewArray('[Ljavax/microedition/lcdui/Command;', Length(Refs));
      FVM.GetObject(R).Elements := Refs;
      LCDPutRef(O, 'commands', R);
      if IsAlert(Args[0].AsRef) then
        AlertChanged(O);
      FDirty := True;
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create('LCDUI method ' + C + '.' + N);
end;

procedure TJ2MELCDUI.Render(var Pixels: TArray<UInt32>; const Content: TArray<UInt32>; Now: Int64);
var
  ClipT, ClipB, ClipL, ClipR: Integer;
  Font: TJ2MEFontView;

  procedure Rect(X, Y, W, H: Integer; Color: UInt32);
  begin
    var FirstY := Max(Int64(ClipT), Int64(Y));
    var LastY := Min(Int64(ClipB), Int64(Y) + H);
    var FirstX := Max(Int64(ClipL), Int64(X));
    var LastX := Min(Int64(ClipR), Int64(X) + W);
    if (FirstX >= LastX) or (FirstY >= LastY) then
      Exit;
    for var Row := Integer(FirstY) to Integer(LastY) - 1 do
      for var Col := Integer(FirstX) to Integer(LastX) - 1 do
        Pixels[Row * FWidth + Col] := Color;
  end;

  procedure Text(const Value: string; X, Y: Integer; Color: UInt32; Limit: Integer = MaxInt; Start: Integer = 0);
  begin
    for var C in Value do
    begin
      if (C = #10) or (C = #13) then
        Break;
      var W := J2MEFontAdvance(Font, C);
      if X >= Min(ClipR, Limit) then
        Break;
      var Glyph := J2MEFontGlyph(Font, C);
      for var Row := 0 to Glyph.Height - 1 do
        if (Y + Row >= ClipT) and (Y + Row < ClipB) then
          for var Col := 0 to Glyph.Width - 1 do
            if (X + Col >= Max(ClipL, Start)) and (X + Col < Min(ClipR, Limit)) and (Glyph.Mask[Row * Glyph.Width + Col] <> 0) then
              Pixels[(Y + Row) * FWidth + X + Col] := Color;
      Inc(X, W);
    end;
  end;

  function StringRef(R: Integer): string;
  begin
    Result := '';
    if R <> 0 then
      Result := FVM.GetObject(R).Text;
  end;

  function CommandLabel(R: Integer; LongLabel: Boolean = False): string;
  begin
    Result := '';
    if R = 0 then
      Exit;
    var O := FVM.GetObject(R);
    var Ref := LCDRef(O, 'label');
    if LongLabel and (LCDRef(O, 'longLabel') <> 0) then
      Ref := LCDRef(O, 'longLabel');
    Result := StringRef(Ref);
    if (Result = '') and (R = SelectCommand(FCurrent)) then
      Result := 'Select';
    if (Result = '') and IsAlert(FCurrent) and (R = AlertCommand) then
      Result := 'OK';
  end;

  procedure Outline(X, Y, W, H: Integer; Color: UInt32);
  begin
    Rect(X, Y, W, 1, Color);
    Rect(X, Y, 1, H, Color);
    Rect(X + W - 1, Y, 1, H, Color);
    var Bottom := Int64(Y) + H - 1;
    if (Bottom >= ClipT) and (Bottom < ClipB) then
      Rect(X, Integer(Bottom), W, 1, Color);
  end;

  procedure Picture(Ref, X, Y: Integer);
  begin
    if Ref = 0 then
      Exit;
    var View := J2MEImageView(FVM, Ref);
    for var Row := Max(0, ClipT - Y) to Min(View.Height, ClipB - Y) - 1 do
      for var Col := Max(0, ClipL - X) to Min(View.Width, ClipR - X) - 1 do
      begin
        var Pixel := UInt32(View.Pixels.Elements[Row * View.Width + Col].AsInt);
        var A := Pixel shr 24;
        if A = 0 then
          Continue;
        var Index := (Y + Row) * FWidth + X + Col;
        var Old := Pixels[Index];
        var B := 255 - A;
        Pixels[Index] := $FF000000 or (((((Pixel shr 16) and 255) * A + ((Old shr 16) and 255) * B + 127) div 255) shl 16) or
          (((((Pixel shr 8) and 255) * A + ((Old shr 8) and 255) * B + 127) div 255) shl 8) or (((Pixel and 255) * A + (Old and 255) * B + 127) div 255);
      end;
  end;

  procedure Editor(Ref, X, Y, W, H: Integer; Active: Boolean; const Cached: TArray<TJ2METextLine>);
  begin
    var O := FVM.GetObject(Ref);
    var Editable := (LCDInt(O, 'constraints') and $20000) = 0;
    var Color: UInt32 := $FFFFFFFF;
    if not Editable then
      Color := $FFE2E9EF;
    Rect(X, Y, W, H, Color);
    Color := $FF8B9BAB;
    if Active then
      Color := $FF2766A4;
    Outline(X, Y, W, H, Color);
    Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
    var Lines := Cached;
    if Length(Lines) = 0 then
    begin
      if (FEditorRef <> Ref) or (FEditorText <> LCDRef(O, 'text')) or (FEditorConstraints <> LCDInt(O, 'constraints')) or
        (FEditorWidth <> W) or (FEditorNegative <> LCDInt(O, 'negativePending')) then
      begin
        FEditorLines := J2MEWrapText(J2METextDisplay(FVM, O), Font, Max(1, W - 8));
        FEditorRef := Ref;
        FEditorText := LCDRef(O, 'text');
        FEditorConstraints := LCDInt(O, 'constraints');
        FEditorWidth := W;
        FEditorNegative := LCDInt(O, 'negativePending');
      end;
      Lines := FEditorLines;
    end;
    var LineHeight := Font.Height + 3;
    var Count := Max(1, (H - 8) div LineHeight);
    var Caret := LCDInt(O, 'caret');
    var Line := J2MECaretLine(Lines, Caret);
    var Scroll := EnsureRange(LCDInt(O, 'editScroll'), 0, Max(0, Length(Lines) - Count));
    if Active then
    begin
      if Line < Scroll then
        Scroll := Line;
      if Line >= Scroll + Count then
        Scroll := Line - Count + 1;
    end;
    LCDPut(O, 'editScroll', Scroll);
    var OldT := ClipT;
    var OldB := ClipB;
    var OldL := ClipL;
    var OldR := ClipR;
    ClipT := Max(ClipT, Y + 2);
    ClipB := Integer(Min(Int64(ClipB), Int64(Y) + H - 2));
    ClipL := Max(ClipL, X + 2);
    ClipR := Min(ClipR, X + W - 2);
    for var I := Scroll to Min(High(Lines), Scroll + Count - 1) do
      Text(Lines[I].Text, X + 4, Y + 4 + (I - Scroll) * LineHeight, $FF152536);
    if Active and Editable then
    begin
      FScrollText := True;
      if ((Now div 500) and 1) = 0 then
      begin
        var Position := EnsureRange(Caret - Lines[Line].Start, 0, Lines[Line].Count);
        var CaretX := X + 4 + J2MEFontTextWidth(Font, Copy(Lines[Line].Text, 1, Position));
        Rect(CaretX, Y + 4 + (Line - Scroll) * LineHeight, 1, Font.Height, $FF152536);
      end;
    end;
    ClipT := OldT;
    ClipB := OldB;
    ClipL := OldL;
    ClipR := OldR;
  end;

  procedure ChoiceRow(Row: TJVMObject; X, Y, W, H: Integer; Selected, Multiple, Active: Boolean);
  begin
    var Color: UInt32 := $FF152536;
    if Active then
    begin
      Rect(X, Y, W, H, $FF2766A4);
      Color := $FFFFFFFF;
    end;
    var Marker := '( )';
    if Multiple then
      Marker := '[ ]';
    if Selected then
      Marker[2] := '*';
    Text(Marker, X + 2, Y + 4, Color);
    var Left := X + 23;
    var Image := LCDRef(Row, 'image');
    if Image <> 0 then
    begin
      var View := J2MEImageView(FVM, Image);
      var OldR := ClipR;
      var OldB := ClipB;
      ClipR := Min(ClipR, Left + 32);
      ClipB := Min(ClipB, Y + 22);
      Picture(Image, Left, Y + 2);
      ClipR := OldR;
      ClipB := OldB;
      Inc(Left, Min(32, View.Width) + 4);
    end;
    var Ref := LCDRef(Row, 'font');
    if Ref = 0 then
      Ref := J2MEGetFont(FVM, 0, 0, 8);
    Font := J2MEFontView(FVM, Ref);
    Text(StringRef(LCDRef(Row, 'text')), Left, Y + 4, Color);
    Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
  end;

  procedure FormBody(Screen, Top, H: Integer);
  begin
    var O := FVM.GetObject(Screen);
    var Focus := FocusedItem(Screen);
    FFormLayout.Update(Screen, Max(1, FWidth - 12), H);
    var Scroll := EnsureRange(LCDInt(O, 'scroll'), 0, Max(0, FFormLayout.TotalHeight - H));
    var Target := LCDRef(O, 'ensureItem');
    if (Target = 0) and (LCDInt(O, 'ensureFocus') <> 0) then
      Target := Focus;
    var Index := FFormLayout.Find(Target);
    if Index >= 0 then
    begin
      var Box := FFormLayout.Boxes[Index];
      var Y := Int64(Box.Y);
      var Height := Box.Height;
      var Item := FVM.GetObject(Box.Ref);
      if (LCDInt(Item, 'itemKind') = 6) and ((LCDInt(Item, 'choiceType') <> 4) or (LCDInt(Item, 'expanded') <> 0)) then
      begin
        var Rows := FVM.GetObject(LCDRef(Item, 'rows'));
        var Choice := EnsureRange(LCDInt(Item, 'focus'), 0, Max(0, High(Rows.Elements)));
        Inc(Y, Box.Metrics.LabelHeight);
        for var I := 0 to Choice - 1 do
          Inc(Y, J2MEChoiceRowHeight(FVM, Rows.Elements[I].AsRef));
        Height := 24;
        if Length(Rows.Elements) > 0 then
          Height := J2MEChoiceRowHeight(FVM, Rows.Elements[Choice].AsRef);
      end;
      if (LCDInt(Item, 'itemKind') = 7) and (LCDInt(Item, 'editing') <> 0) then
      begin
        var Selection, Count: Integer;
        J2MEDateFieldSelection(Item, Selection, Count);
        var F := J2MEFontView(FVM, Box.Metrics.FontRef);
        var Line := J2MECaretLine(Box.Metrics.Lines, Selection + Count - 1);
        Inc(Y, Box.Metrics.LabelHeight + 4 + Line * (F.Height + 3));
        Height := F.Height;
      end;
      if Y < Scroll then
        Scroll := Integer(Y);
      if (Height <= H) and (Y + Height > Int64(Scroll) + H) then
        Scroll := Integer(Min(Int64(MaxInt), Y + Height - H))
      else if Y >= Int64(Scroll) + H then
        Scroll := Integer(Y);
    end;
    Scroll := EnsureRange(Scroll, 0, Max(0, FFormLayout.TotalHeight - H));
    LCDPut(O, 'scroll', Scroll);
    LCDPut(O, 'ensureFocus', 0);
    LCDPutRef(O, 'ensureItem', 0);
    var Bottom := Top + H;
    for var Box in FFormLayout.Boxes do
    begin
      var Base := Int64(Top) + Box.Y - Scroll;
      if (Box.Width <= 0) or (Box.Height <= 0) or (Base >= Bottom) or (Base + Box.Height <= Top) then
        Continue;
      var X := Box.X + 6;
      var Y := Integer(Base);
      var Item := FVM.GetObject(Box.Ref);
      var Kind := LCDInt(Item, 'itemKind');
      ClipL := X;
      ClipR := Min(FWidth - 4, X + Box.Width);
      ClipT := Max(Top, Y);
      ClipB := Integer(Min(Int64(Bottom), Base + Box.Height));
      Font := J2MEFontView(FVM, Box.Metrics.LabelFontRef);
      var LH := Font.Height + 2;
      var First := Max(0, (ClipT - Y) div LH);
      var Last := Min(High(Box.Metrics.Labels), (ClipB - Y) div LH);
      for var I := First to Last do
        Text(Box.Metrics.Labels[I].Text, X + 2, Y + I * LH, $FF234E70);
      var BodyY := Y + Box.Metrics.LabelHeight;
      var BodyHeight := Max(0, Box.Height - Box.Metrics.LabelHeight);
      ClipT := Max(ClipT, BodyY);
      Font := J2MEFontView(FVM, Box.Metrics.FontRef);
      case Kind of
        1:
          begin
            var Mode := LCDInt(Item, 'appearance');
            var Inset := 0;
            if Mode = 2 then
            begin
              Outline(X, BodyY, Box.Width, BodyHeight, $FF8B9BAB);
              Inset := 3;
            end;
            var LineHeight := Font.Height + 3;
            First := Max(0, (ClipT - BodyY - Inset) div LineHeight);
            Last := Min(High(Box.Metrics.Lines), (ClipB - BodyY) div LineHeight);
            var Color: UInt32 := $FF152536;
            if Mode = 1 then
              Color := $FF145CA3;
            for var I := First to Last do
            begin
              var YY := BodyY + Inset + I * LineHeight;
              Text(Box.Metrics.Lines[I].Text, X + 2, YY, Color);
              if Mode = 1 then
                Rect(X + 2, YY + Font.Height, J2MEFontTextWidth(Font, Box.Metrics.Lines[I].Text), 1, Color);
            end;
          end;
        2:
          begin
            var Ref := LCDRef(Item, 'imageSnapshot');
            if Ref <> 0 then
            begin
              var View := J2MEImageView(FVM, Ref);
              Picture(Ref, X + (Box.Width - View.Width) div 2, BodyY);
            end;
          end;
        4:
          begin
            Rect(X, BodyY, Box.Width, 18, $FFB9C4CD);
            Rect(X + 1, BodyY + 1, Max(0, Box.Width - 2), 16, $FFE2E9EF);
            var Maximum := LCDInt(Item, 'maximum');
            var Value := LCDInt(Item, 'value');
            if Maximum > 0 then
              Rect(X + 1, BodyY + 1, Integer(Int64(Max(0, Box.Width - 2)) * Value div Maximum), 16, $FF2766A4)
            else if Value >= 2 then
            begin
              var Phase := Int64(UInt32(LCDInt(Item, 'pulse')));
              if Value = 2 then
              begin
                Phase := Now div 100;
                FScrollText := True;
              end;
              var Part := Max(1, Box.Width div 4);
              var Position := Integer(Phase mod Max(1, Box.Width - Part - 2));
              Rect(X + 1 + Position, BodyY + 1, Part, 16, $FF2766A4);
            end;
          end;
        7:
          begin
            Outline(X, BodyY, Box.Width, BodyHeight, $FF8B9BAB);
            var Selection, Count: Integer;
            J2MEDateFieldSelection(Item, Selection, Count);
            var LineHeight := Font.Height + 3;
            for var I := 0 to High(Box.Metrics.Lines) do
            begin
              var Line := Box.Metrics.Lines[I];
              var YY := BodyY + 4 + I * LineHeight;
              if (Box.Ref = Focus) and (LCDInt(Item, 'editing') <> 0) then
              begin
                var A := Max(Selection, Line.Start);
                var B := Min(Selection + Count, Line.Start + Line.Count);
                if A < B then
                begin
                  var Left := J2MEFontTextWidth(Font, Copy(Line.Text, 1, A - Line.Start));
                  var Width := J2MEFontTextWidth(Font, Copy(Line.Text, A - Line.Start + 1, B - A));
                  Rect(X + 4 + Left, YY, Width, Font.Height, $FFB9D7F2);
                end;
              end;
              Text(Line.Text, X + 4, YY, $FF152536);
            end;
          end;
        5:
          Editor(Box.Ref, X, BodyY, Box.Width, BodyHeight, Box.Ref = Focus, Box.Metrics.Lines);
        6:
          begin
            var Rows := FVM.GetObject(LCDRef(Item, 'rows'));
            var Count := Length(Rows.Elements);
            var Choice := EnsureRange(LCDInt(Item, 'focus'), 0, Max(0, Count - 1));
            var Popup := (LCDInt(Item, 'choiceType') = 4) and (LCDInt(Item, 'expanded') = 0);
            if Popup then
            begin
              Outline(X, BodyY, Box.Width, BodyHeight, $FF8B9BAB);
              if Count > 0 then
              begin
                var Selected := 0;
                for var I := 0 to Count - 1 do
                  if LCDInt(FVM.GetObject(Rows.Elements[I].AsRef), 'selected') <> 0 then
                  begin
                    Selected := I;
                    Break;
                  end;
                ChoiceRow(FVM.GetObject(Rows.Elements[Selected].AsRef), X, BodyY, Box.Width, BodyHeight, True, False, False);
              end;
              Text('v', X + Max(0, Box.Width - 8), BodyY + 4, $FF234E70);
            end
            else
            begin
              var YY := Int64(BodyY);
              for var I := 0 to Count - 1 do
              begin
                var Height := J2MEChoiceRowHeight(FVM, Rows.Elements[I].AsRef);
                if (YY < ClipB) and (YY + Height > ClipT) then
                  ChoiceRow(FVM.GetObject(Rows.Elements[I].AsRef), X, Integer(YY), Box.Width, Height, LCDInt(FVM.GetObject(Rows.Elements[I].AsRef), 'selected') <> 0, LCDInt(Item, 'choiceType') = 2, (Box.Ref = Focus) and (I = Choice));
                Inc(YY, Height);
                if YY >= ClipB then
                  Break;
              end;
            end;
          end;
      end;
      ClipT := Max(Top, Y);
      if (Box.Ref = Focus) and (Kind <> 5) then
        Outline(X, Y, Box.Width, Box.Height, $FF2766A4);
    end;
    ClipL := 0;
    ClipR := FWidth;
    ClipT := Top;
    ClipB := Bottom;
    if FFormLayout.TotalHeight > H then
    begin
      Rect(FWidth - 4, Top, 3, H, $FFDAE2E9);
      var Thumb := Max(8, Integer(Int64(H) * H div FFormLayout.TotalHeight));
      Thumb := Min(Thumb, H);
      var Position := Integer(Int64(Max(0, H - Thumb)) * Scroll div Max(1, FFormLayout.TotalHeight - H));
      Rect(FWidth - 4, Top + Position, 3, Thumb, $FF6B8196);
    end;
    ClipT := 0;
    ClipB := FHeight;
    ClipL := 0;
    ClipR := FWidth;
    Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
  end;

begin
  if FCurrent = 0 then
    Exit;
  FDirty := False;
  FScrollText := False;
  FTickerStep := Now div 50;
  var O := FVM.GetObject(FCurrent);
  Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
  ClipT := 0;
  ClipB := FHeight;
  ClipL := 0;
  ClipR := FWidth;
  var ContentTop := Top(FCurrent);
  var H := ContentHeight(FCurrent);
  var Canvas := IsCanvas(FCurrent);
  if Canvas then
  begin
    for var Row := 0 to H - 1 do
      if (Row + ContentTop < FHeight) then
        for var Col := 0 to FWidth - 1 do
          Pixels[(Row + ContentTop) * FWidth + Col] := Content[Row * FWidth + Col];
  end
  else
    Rect(0, 0, FWidth, FHeight, $FFF4F6F9);
  if ContentTop > 0 then
  begin
    var Y := 0;
    if LCDRef(O, 'title') <> 0 then
    begin
      Rect(0, 0, FWidth, 20, $FF234E70);
      Text(StringRef(LCDRef(O, 'title')), 4, 3, $FFFFFFFF);
      Y := 20;
    end;
    if LCDRef(O, 'ticker') <> 0 then
    begin
      var Ticker := FVM.GetObject(LCDRef(O, 'ticker'));
      var Value := StringRef(LCDRef(Ticker, 'text')).Replace(#13, ' ').Replace(#10, ' ');
      var W := J2MEFontTextWidth(Font, Value);
      var X := FWidth - Integer((Now div 50) mod Max(1, W + FWidth));
      ClipT := Y;
      ClipB := Min(FHeight, Y + 16);
      Rect(0, Y, FWidth, 16, $FFE2E9EF);
      Text(Value, X, Y + 1, $FF152536);
      ClipT := 0;
      ClipB := FHeight;
    end;
  end;
  if FVM.IsAssignable(O.ClassName, ListClass) then
  begin
    var Rows := FVM.GetObject(LCDRef(O, 'rows'));
    var Count := Length(Rows.Elements);
    var Focus := EnsureRange(LCDInt(O, 'focus'), 0, Max(0, Count - 1));
    var Heights: TArray<Integer>;
    SetLength(Heights, Count);
    var Total := 0;
    var FocusTop := 0;
    for var I := 0 to Count - 1 do
    begin
      var Row := FVM.GetObject(Rows.Elements[I].AsRef);
      var F := LCDRef(Row, 'font');
      var Height := 24;
      if F <> 0 then
        Height := Max(Height, J2MEFontView(FVM, F).Height + 8);
      if I = Focus then
        FocusTop := Total;
      Heights[I] := Height;
      Inc(Total, Height);
    end;
    var Scroll := LCDInt(O, 'scroll');
    if FocusTop < Scroll then
      Scroll := FocusTop;
    if (Count > 0) and (FocusTop + Heights[Focus] > Scroll + H) then
      Scroll := Min(FocusTop, FocusTop + Heights[Focus] - H);
    Scroll := EnsureRange(Scroll, 0, Max(0, Total - H));
    LCDPut(O, 'scroll', Scroll);
    var Position := -Scroll;
    ClipT := ContentTop;
    ClipB := Min(FHeight, ContentTop + H);
    for var I := 0 to Count - 1 do
    begin
      var Y := ContentTop + Position;
      Inc(Position, Heights[I]);
      if Y >= ClipB then
        Break;
      if Y + Heights[I] <= ClipT then
        Continue;
      var Row := FVM.GetObject(Rows.Elements[I].AsRef);
      var Color: UInt32 := $FF152536;
      if I = Focus then
      begin
        Rect(0, Y, FWidth, Heights[I], $FF2766A4);
        Color := $FFFFFFFF;
      end;
      var X := 5;
      if LCDInt(O, 'choiceType') <> 3 then
      begin
        var Marker := '( )';
        if LCDInt(O, 'choiceType') = 2 then
          Marker := '[ ]';
        if LCDInt(Row, 'selected') <> 0 then
          Marker[2] := '*';
        Text(Marker, X, Y + 4, Color);
        Inc(X, 22);
      end;
      var Image := LCDRef(Row, 'image');
      if Image <> 0 then
      begin
        var View := J2MEImageView(FVM, Image);
        for var R := 0 to Min(20, View.Height) - 1 do
          for var C := 0 to Min(32, View.Width) - 1 do
            if (X + C < FWidth) and (Y + R + 2 >= ClipT) and (Y + R + 2 < ClipB) then
            begin
              var Pixel := UInt32(View.Pixels.Elements[R * View.Width + C].AsInt);
              var A := Pixel shr 24;
              if A <> 0 then
              begin
                var PixelIndex := (Y + R + 2) * FWidth + X + C;
                var Old := Pixels[PixelIndex];
                var B := 255 - A;
                Pixels[PixelIndex] := $FF000000 or
                  (((((Pixel shr 16) and 255) * A + ((Old shr 16) and 255) * B + 127) div 255) shl 16) or
                  (((((Pixel shr 8) and 255) * A + ((Old shr 8) and 255) * B + 127) div 255) shl 8) or
                  (((Pixel and 255) * A + (Old and 255) * B + 127) div 255);
              end;
            end;
        Inc(X, Min(32, View.Width) + 4);
      end;
      var FontRef := LCDRef(Row, 'font');
      if FontRef <> 0 then
        Font := J2MEFontView(FVM, FontRef);
      var Value := StringRef(LCDRef(Row, 'text')).Replace(#13#10, ' ').Replace(#13, ' ').Replace(#10, ' ');
      var Offset := 0;
      if I = Focus then
      begin
        var Width := J2MEFontTextWidth(Font, Value);
        var Overflow := Max(0, Width - Max(1, FWidth - X - 3));
        if Overflow > 0 then
        begin
          var Start: TJVMValue;
          if not Row.Fields.TryGetValue('$ui.scrollStart', Start) then
          begin
            Start := TJVMValue.Long(Now);
            Row.Fields.Add('$ui.scrollStart', Start);
          end;
          var TextPosition := Integer((Max(Int64(0), Now - Start.AsLong) div 50) mod (Int64(Overflow) * 2 + 80));
          if TextPosition < 40 then
            Offset := 0
          else if TextPosition < Overflow + 40 then
            Offset := TextPosition - 40
          else if TextPosition < Overflow + 80 then
            Offset := Overflow
          else
            Offset := Overflow * 2 + 80 - TextPosition;
          FScrollText := True;
        end;
      end;
      Text(Value, X - Offset, Y + 4, Color, FWidth - 3, X);
      Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
    end;
    ClipT := 0;
    ClipB := FHeight;
  end;
  if IsForm(FCurrent) then
    FormBody(FCurrent, ContentTop, H);
  if IsTextBox(FCurrent) then
  begin
    ClipT := ContentTop;
    ClipB := ContentTop + H;
    Editor(FCurrent, 6, ContentTop + 4, Max(1, FWidth - 12), Max(1, H - 8), True, nil);
    ClipT := 0;
    ClipB := FHeight;
  end;
  if IsAlert(FCurrent) then
  begin
    FAlertLayout.Update(FCurrent, FWidth, H);
    if not FAlertStarted then
    begin
      FAlertStart := Now;
      if FPaused then
        FAlertStart := FPausedAt;
      FAlertStarted := True;
    end;
    var Scroll := EnsureRange(LCDInt(O, 'scroll'), 0, Max(0, FAlertLayout.TotalHeight - H));
    LCDPut(O, 'scroll', Scroll);
    ClipT := ContentTop;
    ClipB := Min(FHeight, ContentTop + H);
    var Kind := LCDRef(O, 'alertType');
    if Kind <> 0 then
    begin
      var Color: UInt32 := $FF2766A4;
      case LCDInt(FVM.GetObject(Kind), 'alertType') of
        2:
          Color := $FFAF7200;
        3:
          Color := $FFB52C35;
        4:
          Color := $FF8845A0;
        5:
          Color := $FF24834A;
      end;
      Rect(0, ContentTop, FWidth, 3, Color);
    end;
    if FAlertLayout.Image <> 0 then
    begin
      var View := J2MEImageView(FVM, FAlertLayout.Image);
      var X := (FWidth - View.Width) div 2;
      var Y := ContentTop + 8 - Scroll;
      for var Row := Max(0, ClipT - Y) to Min(View.Height, ClipB - Y) - 1 do
        for var Col := Max(0, -X) to Min(View.Width, FWidth - X) - 1 do
        begin
          var Pixel := UInt32(View.Pixels.Elements[Row * View.Width + Col].AsInt);
          var A := Pixel shr 24;
          if A <> 0 then
          begin
            var Index := (Y + Row) * FWidth + X + Col;
            var Old := Pixels[Index];
            var B := 255 - A;
            Pixels[Index] := $FF000000 or
              (((((Pixel shr 16) and 255) * A + ((Old shr 16) and 255) * B + 127) div 255) shl 16) or
              (((((Pixel shr 8) and 255) * A + ((Old shr 8) and 255) * B + 127) div 255) shl 8) or
              (((Pixel and 255) * A + (Old and 255) * B + 127) div 255);
          end;
        end;
    end;
    var Y := ContentTop + FAlertLayout.TextY - Scroll;
    var First := Max(0, (ClipT - Y) div FAlertLayout.LineHeight);
    var Last := Min(High(FAlertLayout.Lines), (ClipB - Y) div FAlertLayout.LineHeight);
    for var I := First to Last do
      Text(FAlertLayout.Lines[I], 6, Y + I * FAlertLayout.LineHeight, $FF152536, FWidth - 8);
    if FAlertLayout.Indicator <> 0 then
    begin
      var Gauge := FVM.GetObject(FAlertLayout.Indicator);
      var Top := ContentTop + FAlertLayout.IndicatorY - Scroll;
      var Width := Max(1, FWidth - 16);
      Rect(8, Top, Width, 16, $FFB9C4CD);
      Rect(9, Top + 1, Max(0, Width - 2), 14, $FFE2E9EF);
      var Maximum := LCDInt(Gauge, 'maximum');
      var Value := LCDInt(Gauge, 'value');
      if Maximum > 0 then
        Rect(9, Top + 1, Integer(Int64(Max(0, Width - 2)) * Value div Maximum), 14, $FF2766A4)
      else if Value >= 2 then
      begin
        var Phase := Int64(UInt32(LCDInt(Gauge, 'pulse')));
        if Value = 2 then
        begin
          Phase := Now div 100;
          FScrollText := True;
        end;
        var Part := Max(1, Width div 4);
        var Position := Integer(Phase mod Max(1, Width - Part - 2));
        Rect(9 + Position, Top + 1, Part, 14, $FF2766A4);
      end;
    end;
    if FAlertLayout.TotalHeight > H then
    begin
      if Scroll > 0 then
        Text('^', FWidth - 7, ContentTop, $FF234E70);
      if Scroll < FAlertLayout.TotalHeight - H then
        Text('v', FWidth - 7, Max(ContentTop, ClipB - Font.Height), $FF234E70);
    end;
    ClipT := 0;
    ClipB := FHeight;
  end;
  var Values := Commands(FCurrent);
  var Right := RightCommand(Values);
  var Left: TArray<Integer>;
  for var R in Values do
    if R <> Right then
    begin
      var N := Length(Left);
      SetLength(Left, N + 1);
      Left[N] := R;
    end;
  if not Canvas or (ContentTop + H < FHeight) then
  begin
    var Y := Max(0, FHeight - 20);
    Rect(0, Y, FWidth, 20, $FF234E70);
    var L := '';
    if Length(Left) = 1 then
      L := CommandLabel(Left[0])
    else if Length(Left) > 1 then
      L := 'Options';
    var R := CommandLabel(Right);
    if ChoicePopup(FCurrent) then
    begin
      L := 'Select';
      R := 'Cancel';
    end;
    Text(L, 3, Y + 3, $FFFFFFFF, FWidth div 2);
    Text(R, Max(FWidth div 2, FWidth - J2MEFontTextWidth(Font, R) - 3), Y + 3, $FFFFFFFF);
    var Edit := FocusedItem(FCurrent);
    if IsTextBox(FCurrent) then
      Edit := FCurrent;
    if (Edit <> 0) and (IsTextBox(FCurrent) or (LCDInt(FVM.GetObject(Edit), 'itemKind') = 5)) and not ChoicePopup(FCurrent) then
    begin
      var Target := FVM.GetObject(Edit);
      var Mode := 'abc';
      var Kind := LCDInt(Target, 'constraints') and $FFFF;
      if (LCDInt(Target, 'inputMode') = 2) or (Kind = 2) or (Kind = 3) or (Kind = 5) then
        Mode := '123'
      else if LCDInt(Target, 'inputMode') = 1 then
        Mode := 'ABC';
      Text(Mode, (FWidth - J2MEFontTextWidth(Font, Mode)) div 2, Y + 3, $FFBCD2E2);
    end;
  end;
  if FMenu then
  begin
    FMenuIndex := EnsureRange(FMenuIndex, 0, Max(0, High(Values)));
    var Page := Max(1, (FHeight - 24) div 22);
    var First := Max(0, FMenuIndex - Page + 1);
    Rect(2, 2, FWidth - 4, FHeight - 4, $FFF4F6F9);
    Text('Options', 6, 4, $FF152536);
    for var I := First to Min(High(Values), First + Page - 1) do
    begin
      var Y := 22 + (I - First) * 22;
      var Color: UInt32 := $FF152536;
      if I = FMenuIndex then
      begin
        Rect(4, Y, FWidth - 8, 22, $FF2766A4);
        Color := $FFFFFFFF;
      end;
      Text(CommandLabel(Values[I], True), 7, Y + 3, Color);
    end;
  end;
end;

end.

