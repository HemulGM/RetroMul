unit RM.Settings.Template.Path;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects,
  FMX.Controls.Presentation;

type
  TSettingsPathTemplate = class(TFrame)
    PanelSetting: TPanel;
    LayoutSettingText: TLayout;
    LabelSettingTitle: TLabel;
    LabelSettingDetail: TLabel;
    LayoutSettingEditorContainer: TLayout;
    EditSettingEditor: TEdit;
    EditButtonSettingBrowse: TEditButton;
    PathSettingBrowseIcon: TPath;
    PathFolderBrowseIcon: TPath;
    EditButtonSettingClear: TEditButton;
  end;

implementation

{$R *.fmx}

end.

