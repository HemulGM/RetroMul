unit RM.Settings.Binding;

interface

uses
  System.Classes, System.SysUtils, FMX.Types, FMX.Controls, FMX.Forms,
  FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.EditBox, FMX.ListBox, FMX.SpinBox,
  FMX.Text, RM.Settings.Builder;

type
  // All visual references are established at construction, never rediscovered
  // through names, parents, component tags or child positions.
  TSettingsRowView = class
  public
    Template: TFrame;
    Panel: TPanel;
    Text, Editors: TLayout;
    Title, Detail, ValueLabel: TLabel;
    Editor: TControl;
    Browse, Clear: TEditButton;
    Folder, CustomLayout: Boolean;
  end;

  TSettingsGroupView = class
  public
    Definition: TSettingsGroup;
    Template: TFrame;
    Panel: TPanel;
    Title: TLabel;
  end;

  TSettingsBinding = class abstract
  private
    function GetSection: string;
    function GetKey: string;
    function GetDefaultValue: string;
    function GetValues: TArray<string>;
  public
    Definition: TSettingsFieldDefinition;
    RowView: TSettingsRowView;
    Control: TControl;
    Row: TPanel;
    ChangeHandler: TNotifyEvent;
    procedure Load; virtual; abstract;
    function Pull: Boolean; virtual; abstract;
    property Section: string read GetSection;
    property Key: string read GetKey;
    property DefaultValue: string read GetDefaultValue;
    property Values: TArray<string> read GetValues;
  end;

  TBooleanSettingsBinding = class(TSettingsBinding)
  public
    procedure Load; override;
    function Pull: Boolean; override;
  end;

  TChoiceSettingsBinding = class(TSettingsBinding)
  public
    procedure Load; override;
    function Pull: Boolean; override;
  end;

  TIntegerSettingsBinding = class(TSettingsBinding)
  public
    procedure Load; override;
    function Pull: Boolean; override;
  end;

  TTextSettingsBinding = class(TSettingsBinding)
  public
    procedure Load; override;
    function Pull: Boolean; override;
  end;

  TSliderSettingsBinding = class(TSettingsBinding)
  public
    procedure Load; override;
    function Pull: Boolean; override;
  end;

implementation

function TSettingsBinding.GetSection: string;
begin
  Result := Definition.Section;
end;

function TSettingsBinding.GetKey: string;
begin
  Result := Definition.Key;
end;

function TSettingsBinding.GetDefaultValue: string;
begin
  Result := Definition.DefaultValue;
end;

function TSettingsBinding.GetValues: TArray<string>;
begin
  Result := nil;
  if Definition is TChoiceSetting then
  begin
    var Choice := TChoiceSetting(Definition);
    SetLength(Result, Length(Choice.Items));
    for var I := 0 to High(Result) do
      Result[I] := Choice.Items[I].Value;
  end;
end;

procedure TBooleanSettingsBinding.Load;
begin
  TSwitch(Control).IsChecked := TBooleanSetting(Definition).Value;
end;

function TBooleanSettingsBinding.Pull: Boolean;
begin
  var Field := TBooleanSetting(Definition);
  Result := Field.Value <> TSwitch(Control).IsChecked;
  if Result then
    Field.Value := TSwitch(Control).IsChecked;
end;

procedure TChoiceSettingsBinding.Load;
begin
  var Field := TChoiceSetting(Definition);
  var Combo := TComboBox(Control);
  Combo.Items.Clear;
  var Selected := -1;
  var Fallback := -1;
  for var I := 0 to High(Field.Items) do
  begin
    Combo.Items.Add(Translate(Field.Items[I].Caption));
    if SameText(Field.Items[I].Value, Field.Value) then
      Selected := I;
    if SameText(Field.Items[I].Value, Field.DefaultValue) then
      Fallback := I;
  end;
  if Selected < 0 then
    Selected := Fallback;
  if (Selected < 0) and (Length(Field.Items) > 0) then
    Selected := 0;
  Combo.ItemIndex := Selected;
end;

function TChoiceSettingsBinding.Pull: Boolean;
begin
  var Field := TChoiceSetting(Definition);
  var Index := TComboBox(Control).ItemIndex;
  Result := (Index >= 0) and (Index < Length(Field.Items));
  if not Result then
    Exit;
  Result := not SameText(Field.Value, Field.Items[Index].Value);
  if Result then
    Field.Value := Field.Items[Index].Value;
end;

procedure TIntegerSettingsBinding.Load;
begin
  var Field := TIntegerSetting(Definition);
  var Number := TSpinBox(Control);
  Number.Min := Field.Min;
  Number.Max := Field.Max;
  Number.ValueType := TNumValueType.Integer;
  Number.Value := Field.Value;
end;

function TIntegerSettingsBinding.Pull: Boolean;
begin
  var Field := TIntegerSetting(Definition);
  var Value := Round(TSpinBox(Control).Value);
  Result := Field.Value <> Value;
  if Result then
    Field.Value := Value;
end;

procedure TTextSettingsBinding.Load;
begin
  TEdit(Control).Text := TTextSetting(Definition).Value;
end;

function TTextSettingsBinding.Pull: Boolean;
begin
  var Field := TTextSetting(Definition);
  var Value := TEdit(Control).Text.Trim;
  Result := Field.Value <> Value;
  if Result then
    Field.Value := Value;
end;

procedure TSliderSettingsBinding.Load;
begin
  var Field := TSliderSetting(Definition);
  var Slider := TTrackBar(Control);
  Slider.Min := Field.Min;
  Slider.Max := Field.Max;
  Slider.Value := Field.Value;
end;

function TSliderSettingsBinding.Pull: Boolean;
begin
  var Field := TSliderSetting(Definition);
  var Value := TTrackBar(Control).Value;
  Result := Abs(Field.Value - Value) > 0.0001;
  if Result then
    Field.SetValue(Value);
end;

end.

