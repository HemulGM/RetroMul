unit RM.Settings.Template.Interval;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects,
  FMX.Controls.Presentation;

type
  TSettingsIntervalTemplate = class(TFrame)
    PanelSetting: TPanel;
    LayoutSettingText: TLayout;
    LabelSettingTitle: TLabel;
    LabelSettingDetail: TLabel;
    LayoutSettingEditorContainer: TLayout;
    LayoutAutosaveInterval: TLayout;
    SwitchAutosavePeriodic: TSwitch;
    LayoutAutosaveMinutesSlot: TLayout;
  end;

implementation

{$R *.fmx}

end.

