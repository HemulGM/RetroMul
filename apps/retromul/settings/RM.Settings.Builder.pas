unit RM.Settings.Builder;

interface

{$SCOPEDENUMS ON}

uses
  System.SysUtils, System.Classes, System.IniFiles, System.Generics.Collections;

type
  TSettingsApplyMode = (OnApply, OnReset, OnNextLoad);

  TSettingsCondition = reference to function: Boolean;

  TSettingsFieldKind = (BooleanValue, Choice, IntegerValue, Text, Path, Slider);

  TSettingsPageElement = class
  end;

  TSettingsGroup = class(TSettingsPageElement)
  public
    Id, Caption: string;
    Preview, Emphasized: Boolean;
    TitleSize: Single;
    VisibleWhen: TSettingsCondition;
  end;

  TSettingsFieldDefinition = class abstract(TSettingsPageElement)
  private
    FDraft: TMemIniFile;
  public
    Id, Caption, Description, Section, Key, DefaultValue: string;
    Group: TSettingsGroup;
    Kind: TSettingsFieldKind;
    ApplyMode: TSettingsApplyMode;
    SingleLineDescription: Boolean;
    OnChange: TNotifyEvent;
    EnabledWhen, VisibleWhen: TSettingsCondition;
    ValidateValue: TProc;
    constructor Create(Draft: TMemIniFile);
    procedure Validate; virtual;
    procedure Reset;
    property Draft: TMemIniFile read FDraft;
  end;

  TBooleanSetting = class(TSettingsFieldDefinition)
  private
    function GetValue: Boolean;
    procedure SetValue(Value: Boolean);
  public
    property Value: Boolean read GetValue write SetValue;
    function IsTrue: TSettingsCondition;
  end;

  TSettingsChoiceItem = record
    Caption, Value: string;
    class function Make(const Caption, Value: string): TSettingsChoiceItem; static;
  end;

  TChoiceSetting = class(TSettingsFieldDefinition)
  private
    function GetValue: string;
    procedure SetValue(const Value: string);
  public
    Items: TArray<TSettingsChoiceItem>;
    property Value: string read GetValue write SetValue;
  end;

  TIntegerSetting = class(TSettingsFieldDefinition)
  private
    function GetValue: Integer;
    procedure SetValue(Value: Integer);
  public
    Min, Max: Integer;
    property Value: Integer read GetValue write SetValue;
    procedure Validate; override;
  end;

  TTextSetting = class(TSettingsFieldDefinition)
  private
    function GetValue: string;
    procedure SetValue(const Value: string);
  public
    property Value: string read GetValue write SetValue;
  end;

  TPathSetting = class(TTextSetting)
  public
    Folder, AllowEmpty, AllowClear: Boolean;
    FileFilter, PickerTitle: string;
  end;

  TSliderSetting = class(TSettingsFieldDefinition)
  public
    Min, Max, Scale: Single;
    IntegerStorage: Boolean;
    UnitCaption: string;
    function Value: Single;
    procedure SetValue(Value: Single);
  end;

  TSettingsBlockDefinition = class(TSettingsPageElement)
  public
    Id, Caption, Description: string;
    Group: TSettingsGroup;
  end;

  TSettingsInformation = class(TSettingsBlockDefinition)
  public
    Text: string;
  end;

  TSettingsAction = class(TSettingsBlockDefinition)
  public
    ActionCaption: string;
    OnExecute: TNotifyEvent;
  end;

  TSettingsSelection = class(TSettingsBlockDefinition)
  public
    Items: TArray<string>;
    Index: Integer;
    OnChange: TNotifyEvent;
  end;

  TSettingsPageDefinition = class
  private
    FGroups: TObjectList<TSettingsGroup>;
    FFields: TObjectList<TSettingsFieldDefinition>;
    FBlocks: TObjectList<TSettingsBlockDefinition>;
    FItems: TList<TSettingsPageElement>;
  public
    Draft: TMemIniFile;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Validate;
    property Groups: TObjectList<TSettingsGroup> read FGroups;
    property Fields: TObjectList<TSettingsFieldDefinition> read FFields;
    property Blocks: TObjectList<TSettingsBlockDefinition> read FBlocks;
    property Items: TList<TSettingsPageElement> read FItems;
  end;

  // A definition has no FMX references. Callbacks are supplied by the renderer;
  // the same page can also be constructed and validated without a window.
  TSettingsPageBuilder = class
  private
    FDefinition: TSettingsPageDefinition;
    FGroups: TObjectList<TSettingsGroup>;
    FFields: TObjectList<TSettingsFieldDefinition>;
    function GetDraft: TMemIniFile;
    procedure SetDraft(Value: TMemIniFile);
    procedure Add(Field: TSettingsFieldDefinition; const Id, Caption, Description, Section, Key, Default: string);
  public
    PageId: string;
    CurrentGroup: TSettingsGroup;
    OnGroup: TProc<TSettingsGroup>;
    OnField: TProc<TSettingsFieldDefinition>;
    OnBlock: TProc<TSettingsBlockDefinition>;
    OnRebuild: TNotifyEvent;
    OnBindings: TProc<Integer, string>;
    OnPalette: TProc<TChoiceSetting>;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Heading(const Id, Caption: string; Emphasized: Boolean = False; Preview: Boolean = False; TitleSize: Single = 20): TSettingsGroup;
    function AddBoolean(const Id, Caption, Description, Section, Key: string; Default: Boolean; SingleLineDescription: Boolean = False): TBooleanSetting;
    function AddChoice(const Id, Caption, Description, Section, Key: string; const Items: array of TSettingsChoiceItem; const Default: string; SingleLineDescription: Boolean = False): TChoiceSetting;
    function AddInteger(const Id, Caption, Description, Section, Key: string; Default, Maximum: Integer; SingleLineDescription: Boolean = False): TIntegerSetting;
    function AddText(const Id, Caption, Description, Section, Key, Default: string; SingleLineDescription: Boolean = False): TTextSetting;
    function AddPath(const Id, Caption, Description, Section, Key, Default: string; Folder: Boolean; SingleLineDescription: Boolean = False): TPathSetting;
    function AddSlider(const Id, Caption, Description, Section, Key: string; Default, Minimum, Maximum, Scale: Single; IntegerStorage: Boolean): TSliderSetting;
    procedure AddBlock(Block: TSettingsBlockDefinition; const Id, Caption, Description: string);
    function AddInformation(const Id, Caption, Description, Text: string): TSettingsInformation;
    function AddAction(const Id, Caption, Description, ActionCaption: string; OnExecute: TNotifyEvent): TSettingsAction;
    function AddSelection(const Id, Caption, Description: string; const Items: array of string; Index: Integer; OnChange: TNotifyEvent): TSettingsSelection;
    procedure PalettePreview(Palette: TChoiceSetting);
    procedure BuildBindings(Port: Integer; const Device: string);
    procedure Validate;
    property Groups: TObjectList<TSettingsGroup> read FGroups;
    property Fields: TObjectList<TSettingsFieldDefinition> read FFields;
    // Borrowed from TSettingsSession, never owned by a page.
    property Draft: TMemIniFile read GetDraft write SetDraft;
    property Definition: TSettingsPageDefinition read FDefinition;
  end;

function SettingChoice(const Caption, Value: string): TSettingsChoiceItem;

function SettingChoices(const Captions, Values: array of string): TArray<TSettingsChoiceItem>;

implementation

uses
  System.Math;

function SettingChoice(const Caption, Value: string): TSettingsChoiceItem;
begin
  Result := TSettingsChoiceItem.Make(Caption, Value);
end;

function SettingChoices(const Captions, Values: array of string): TArray<TSettingsChoiceItem>;
begin
  if Length(Captions) <> Length(Values) then
    raise EArgumentException.Create('Settings choices require one caption per value');
  SetLength(Result, Length(Values));
  for var I := 0 to High(Values) do
    Result[I] := SettingChoice(Captions[I], Values[I]);
end;

constructor TSettingsFieldDefinition.Create(Draft: TMemIniFile);
begin
  inherited Create;
  FDraft := Draft;
end;

procedure TSettingsFieldDefinition.Validate;
begin
  if Assigned(ValidateValue) then
    ValidateValue();
end;

procedure TSettingsFieldDefinition.Reset;
begin
  FDraft.WriteString(Section, Key, DefaultValue);
end;

function TBooleanSetting.GetValue: Boolean;
begin
  Result := Draft.ReadBool(Section, Key, StrToIntDef(DefaultValue, 0) <> 0);
end;

procedure TBooleanSetting.SetValue(Value: Boolean);
begin
  Draft.WriteBool(Section, Key, Value);
end;

function TBooleanSetting.IsTrue: TSettingsCondition;
begin
  Result :=
    function: Boolean
    begin
      Result := Value;
    end;
end;

class function TSettingsChoiceItem.Make(const Caption, Value: string): TSettingsChoiceItem;
begin
  Result.Caption := Caption;
  Result.Value := Value;
end;

function TChoiceSetting.GetValue: string;
begin
  Result := Draft.ReadString(Section, Key, DefaultValue);
end;

procedure TChoiceSetting.SetValue(const Value: string);
begin
  Draft.WriteString(Section, Key, Value);
end;

function TIntegerSetting.GetValue: Integer;
begin
  Result := EnsureRange(Draft.ReadInteger(Section, Key, StrToIntDef(DefaultValue, 0)), Min, Max);
end;

procedure TIntegerSetting.SetValue(Value: Integer);
begin
  Draft.WriteInteger(Section, Key, EnsureRange(Value, Min, Max));
end;

procedure TIntegerSetting.Validate;
begin
  if Min > Max then
    raise EArgumentException.Create('Invalid settings range: ' + Id);
  inherited;
end;

function TTextSetting.GetValue: string;
begin
  Result := Draft.ReadString(Section, Key, DefaultValue);
end;

procedure TTextSetting.SetValue(const Value: string);
begin
  Draft.WriteString(Section, Key, Value);
end;

function TSliderSetting.Value: Single;
var
  Number: Double;
begin
  Number := StrToFloatDef(DefaultValue, 0, TFormatSettings.Invariant);
  if IntegerStorage then
    Number := Draft.ReadInteger(Section, Key, Round(Number))
  else
    Number := Draft.ReadFloat(Section, Key, Number);
  Result := EnsureRange(Number * Scale, Min, Max);
end;

procedure TSliderSetting.SetValue(Value: Single);
begin
  if IntegerStorage then
    Draft.WriteInteger(Section, Key, Round(Value / Scale))
  else
    Draft.WriteFloat(Section, Key, Value / Scale);
end;

constructor TSettingsPageBuilder.Create;
begin
  inherited;
  FDefinition := TSettingsPageDefinition.Create;
  FGroups := FDefinition.Groups;
  FFields := FDefinition.Fields;
end;

destructor TSettingsPageBuilder.Destroy;
begin
  FDefinition.Free;
  inherited;
end;

procedure TSettingsPageBuilder.Clear;
begin
  CurrentGroup := nil;
  FDefinition.Clear;
end;

constructor TSettingsPageDefinition.Create;
begin
  inherited;
  FGroups := TObjectList<TSettingsGroup>.Create;
  FFields := TObjectList<TSettingsFieldDefinition>.Create;
  FBlocks := TObjectList<TSettingsBlockDefinition>.Create;
  FItems := TList<TSettingsPageElement>.Create;
end;

destructor TSettingsPageDefinition.Destroy;
begin
  FItems.Free;
  FBlocks.Free;
  FFields.Free;
  FGroups.Free;
  inherited;
end;

procedure TSettingsPageDefinition.Clear;
begin
  FItems.Clear;
  FBlocks.Clear;
  FFields.Clear;
  FGroups.Clear;
end;

procedure TSettingsPageDefinition.Validate;
begin
  for var Field in FFields do
    Field.Validate;
end;

function TSettingsPageBuilder.GetDraft: TMemIniFile;
begin
  Result := FDefinition.Draft;
end;

procedure TSettingsPageBuilder.SetDraft(Value: TMemIniFile);
begin
  FDefinition.Draft := Value;
end;

procedure TSettingsPageBuilder.AddBlock(Block: TSettingsBlockDefinition; const Id, Caption, Description: string);
begin
  try
    if (CurrentGroup = nil) or (Id = '') then
      raise EArgumentException.Create('Incomplete settings block: ' + Id);
    for var Field in FFields do
      if SameText(Field.Id, Id) then
        raise EArgumentException.Create('Duplicate settings item: ' + Id);
    for var Existing in FDefinition.Blocks do
      if SameText(Existing.Id, Id) then
        raise EArgumentException.Create('Duplicate settings item: ' + Id);
    Block.Id := Id;
    Block.Caption := Caption;
    Block.Description := Description;
    Block.Group := CurrentGroup;
  except
    Block.Free;
    raise;
  end;
  FDefinition.Blocks.Add(Block);
  FDefinition.Items.Add(Block);
  if Assigned(OnBlock) then
    OnBlock(Block);
end;

function TSettingsPageBuilder.AddInformation(const Id, Caption, Description, Text: string): TSettingsInformation;
begin
  Result := TSettingsInformation.Create;
  Result.Text := Text;
  AddBlock(Result, Id, Caption, Description);
end;

function TSettingsPageBuilder.AddAction(const Id, Caption, Description, ActionCaption: string; OnExecute: TNotifyEvent): TSettingsAction;
begin
  Result := TSettingsAction.Create;
  Result.ActionCaption := ActionCaption;
  Result.OnExecute := OnExecute;
  AddBlock(Result, Id, Caption, Description);
end;

function TSettingsPageBuilder.AddSelection(const Id, Caption, Description: string; const Items: array of string; Index: Integer; OnChange: TNotifyEvent): TSettingsSelection;
begin
  Result := TSettingsSelection.Create;
  SetLength(Result.Items, Length(Items));
  for var I := 0 to High(Items) do
    Result.Items[I] := Items[I];
  Result.Index := Index;
  Result.OnChange := OnChange;
  AddBlock(Result, Id, Caption, Description);
end;

function TSettingsPageBuilder.Heading(const Id, Caption: string; Emphasized, Preview: Boolean; TitleSize: Single): TSettingsGroup;
begin
  for var Existing in FGroups do
    if SameText(Existing.Id, Id) then
      raise EArgumentException.Create('Duplicate settings group: ' + Id);
  Result := TSettingsGroup.Create;
  Result.Id := Id;
  Result.Caption := Caption;
  Result.Preview := Preview;
  Result.Emphasized := Emphasized;
  Result.TitleSize := TitleSize;
  FGroups.Add(Result);
  FDefinition.Items.Add(Result);
  CurrentGroup := Result;
  if Assigned(OnGroup) then
    OnGroup(Result);
end;

procedure TSettingsPageBuilder.Add(Field: TSettingsFieldDefinition; const Id, Caption, Description, Section, Key, Default: string);
begin
  try
    if (CurrentGroup = nil) or (Id = '') or (Section = '') or (Key = '') then
      raise EArgumentException.Create('Incomplete settings field: ' + Id);
    for var Existing in FFields do
      if SameText(Existing.Id, Id) then
        raise EArgumentException.Create('Duplicate settings field: ' + Id);
    for var Block in FDefinition.Blocks do
      if SameText(Block.Id, Id) then
        raise EArgumentException.Create('Duplicate settings item: ' + Id);
    Field.Id := Id;
    Field.Caption := Caption;
    Field.Description := Description;
    Field.Section := Section;
    Field.Key := Key;
    Field.DefaultValue := Default;
    Field.Group := CurrentGroup;
  except
    Field.Free;
    raise;
  end;
  FFields.Add(Field);
  FDefinition.Items.Add(Field);
  if Assigned(OnField) then
    OnField(Field);
end;

function TSettingsPageBuilder.AddBoolean(const Id, Caption, Description, Section, Key: string; Default: Boolean; SingleLineDescription: Boolean): TBooleanSetting;
begin
  Result := TBooleanSetting.Create(Draft);
  Result.Kind := TSettingsFieldKind.BooleanValue;
  Result.SingleLineDescription := SingleLineDescription;
  Add(Result, Id, Caption, Description, Section, Key, IntToStr(Ord(Default)));
end;

function TSettingsPageBuilder.AddChoice(const Id, Caption, Description, Section, Key: string; const Items: array of TSettingsChoiceItem; const Default: string; SingleLineDescription: Boolean): TChoiceSetting;
begin
  Result := TChoiceSetting.Create(Draft);
  Result.Kind := TSettingsFieldKind.Choice;
  SetLength(Result.Items, Length(Items));
  for var I := 0 to High(Items) do
    Result.Items[I] := Items[I];
  Result.SingleLineDescription := SingleLineDescription;
  Add(Result, Id, Caption, Description, Section, Key, Default);
end;

function TSettingsPageBuilder.AddInteger(const Id, Caption, Description, Section, Key: string; Default, Maximum: Integer; SingleLineDescription: Boolean): TIntegerSetting;
begin
  Result := TIntegerSetting.Create(Draft);
  Result.Kind := TSettingsFieldKind.IntegerValue;
  Result.Max := Maximum;
  Result.SingleLineDescription := SingleLineDescription;
  Add(Result, Id, Caption, Description, Section, Key, IntToStr(Default));
end;

function TSettingsPageBuilder.AddText(const Id, Caption, Description, Section, Key, Default: string; SingleLineDescription: Boolean): TTextSetting;
begin
  Result := TTextSetting.Create(Draft);
  Result.Kind := TSettingsFieldKind.Text;
  Result.SingleLineDescription := SingleLineDescription;
  Add(Result, Id, Caption, Description, Section, Key, Default);
end;

function TSettingsPageBuilder.AddPath(const Id, Caption, Description, Section, Key, Default: string; Folder: Boolean; SingleLineDescription: Boolean): TPathSetting;
begin
  Result := TPathSetting.Create(Draft);
  Result.Kind := TSettingsFieldKind.Path;
  Result.FileFilter := 'All files|*.*';
  Result.PickerTitle := 'Choose file';
  Result.Folder := Folder;
  Result.AllowEmpty := True;
  Result.AllowClear := not Folder;
  Result.SingleLineDescription := SingleLineDescription;
  Add(Result, Id, Caption, Description, Section, Key, Default);
end;

function TSettingsPageBuilder.AddSlider(const Id, Caption, Description, Section, Key: string; Default, Minimum, Maximum, Scale: Single; IntegerStorage: Boolean): TSliderSetting;
begin
  if Scale <= 0 then
    raise EArgumentException.Create('Invalid settings slider scale');
  Result := TSliderSetting.Create(Draft);
  Result.Kind := TSettingsFieldKind.Slider;
  Result.Min := Minimum;
  Result.Max := Maximum;
  Result.Scale := Scale;
  Result.IntegerStorage := IntegerStorage;
  Add(Result, Id, Caption, Description, Section, Key,
    FloatToStr(Default, TFormatSettings.Invariant));
end;

procedure TSettingsPageBuilder.PalettePreview(Palette: TChoiceSetting);
begin
  if Assigned(OnPalette) then
    OnPalette(Palette);
end;

procedure TSettingsPageBuilder.BuildBindings(Port: Integer; const Device: string);
begin
  if Assigned(OnBindings) then
    OnBindings(Port, Device);
end;

procedure TSettingsPageBuilder.Validate;
begin
  FDefinition.Validate;
end;

end.
