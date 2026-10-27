unit RM.Settings.Template.Row;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects,
  FMX.Controls.Presentation;

type
  TSettingsRowTemplate = class(TFrame)
    PanelSetting: TPanel;
    LayoutSettingText: TLayout;
    LabelSettingTitle: TLabel;
    LabelSettingDetail: TLabel;
    LayoutSettingEditorContainer: TLayout;
    LayoutSettingEditorSlot: TLayout;
  end;

implementation

{$R *.fmx}

end.

