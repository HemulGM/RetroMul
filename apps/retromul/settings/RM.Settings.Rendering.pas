unit RM.Settings.Rendering;

interface

{$SCOPEDENUMS ON}

uses
  System.Classes, System.SysUtils, FMX.Types, FMX.Controls, FMX.Forms,
  FMX.Layouts, FMX.StdCtrls, FMX.Edit, RM.Settings.Binding, RM.Settings.Builder,
  RM.Settings.Template.Group, RM.Settings.Template.Row,
  RM.Settings.Template.Path, RM.Settings.Template.Interval,
  RM.Settings.Template.Volume, RM.Settings.Template.Track,
  RM.Settings.Template.Preview, RM.Settings.Template.Binding,
  RM.Settings.Template.Device;

type
  TSettingsRowKind = (Standard, Path, Interval, Volume, Track, Preview, Binding, Device);

  // Custom FMX content extends the UI-neutral page definition through a
  // typed factory. New pages need no case branch in the common window.
  TSettingsControlFactory = reference to function(Row: TSettingsRowView): TControl;

  TSettingsControlDefinition = class(TSettingsBlockDefinition)
  public
    RowKind: TSettingsRowKind;
    Factory: TSettingsControlFactory;
  end;

function AddSettingsControl(Page: TSettingsPageBuilder; const Id, Caption, Description: string; RowKind: TSettingsRowKind; const Factory: TSettingsControlFactory): TSettingsControlDefinition;

function CreateSettingsRow(Owner: TComponent; Kind: TSettingsRowKind; const Id, Caption, Description: string): TSettingsRowView;

procedure DisconnectSettingsControl(Control: TControl);

procedure RetireSettingsControl(Control: TControl);

implementation

uses
  FMX.ListBox, FMX.SpinBox;

type
  TSettingsControlAccess = class(TControl);

function AddSettingsControl(Page: TSettingsPageBuilder; const Id, Caption, Description: string; RowKind: TSettingsRowKind; const Factory: TSettingsControlFactory): TSettingsControlDefinition;
begin
  Result := TSettingsControlDefinition.Create;
  Result.RowKind := RowKind;
  Result.Factory := Factory;
  Page.AddBlock(Result, Id, Caption, Description);
end;

procedure DisconnectSettingsControl(Control: TControl);
begin
  // Clear FMX's reference as well as its native capture before detaching.
  var Root := Control.Root;
  if (Root <> nil) and (Root.Captured <> nil) then
  begin
    var Captured := Root.Captured.GetObject;
    if (Captured = Control) or Control.IsChild(Captured) then
      Root.SetCaptured(nil);
  end;
  var ControlAccess := TSettingsControlAccess(Control);
  ControlAccess.OnClick := nil;
  ControlAccess.OnDblClick := nil;
  ControlAccess.OnMouseDown := nil;
  ControlAccess.OnMouseUp := nil;
  ControlAccess.OnMouseMove := nil;
  ControlAccess.OnMouseWheel := nil;
  ControlAccess.OnResize := nil;
  ControlAccess.OnKeyDown := nil;
  ControlAccess.OnKeyUp := nil;
  ControlAccess.OnEnter := nil;
  ControlAccess.OnExit := nil;
  ControlAccess.TagObject := nil;
  if Control is TComboBox then
    TComboBox(ControlAccess).OnChange := nil;
  if Control is TSwitch then
    TSwitch(ControlAccess).OnSwitch := nil;
  if Control is TSpinBox then
    TSpinBox(ControlAccess).OnChange := nil;
  if Control is TEdit then
    TEdit(ControlAccess).OnChangeTracking := nil;
  if Control is TTrackBar then
    TTrackBar(ControlAccess).OnChange := nil;
  if ControlAccess.ChildrenCount > 0 then
    for var Child in ControlAccess.Children.ToArray do
      if Child is TControl then
        DisconnectSettingsControl(TControl(Child));
  Control.Name := '';
end;

procedure RetireSettingsControl(Control: TControl);
begin
  DisconnectSettingsControl(Control);
  Control.Visible := False;
  Control.Parent := nil;
  Control.Release;
end;

function CreateSettingsRow(Owner: TComponent; Kind: TSettingsRowKind; const Id, Caption, Description: string): TSettingsRowView;
begin
  Result := TSettingsRowView.Create;
  try
    case Kind of
      TSettingsRowKind.Standard:
        begin
          var F := TSettingsRowTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
        end;
      TSettingsRowKind.Path:
        begin
          var F := TSettingsPathTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
          Result.Editor := F.EditSettingEditor;
          Result.Browse := F.EditButtonSettingBrowse;
          Result.Clear := F.EditButtonSettingClear;
        end;
      TSettingsRowKind.Interval:
        begin
          var F := TSettingsIntervalTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
          Result.Editor := F.SwitchAutosavePeriodic;
        end;
      TSettingsRowKind.Volume:
        begin
          var F := TSettingsVolumeTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
          Result.ValueLabel := F.LabelVolumeValue;
        end;
      TSettingsRowKind.Track:
        begin
          var F := TSettingsTrackTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
          Result.ValueLabel := F.LabelSettingValue;
        end;
      TSettingsRowKind.Preview:
        begin
          var F := TSettingsPreviewTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
        end;
      TSettingsRowKind.Binding:
        begin
          var F := TSettingsBindingTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
        end;
      TSettingsRowKind.Device:
        begin
          var F := TSettingsDeviceTemplate.Create(nil);
          Result.Template := F;
          Result.Panel := F.PanelSetting;
          Result.Text := F.LayoutSettingText;
          Result.Title := F.LabelSettingTitle;
          Result.Detail := F.LabelSettingDetail;
          Result.Editors := F.LayoutSettingEditorContainer;
        end;
    end;
    Result.Template.Name := '';
    Owner.InsertComponent(Result.Template);
    Result.Title.Text := Translate(Caption);
    Result.Detail.Text := Translate(Description);
    Result.Panel.TagString := Result.Title.Text + ' ' + Result.Detail.Text;
  except
    Result.Template.Free;
    Result.Free;
    raise;
  end;
end;

end.

