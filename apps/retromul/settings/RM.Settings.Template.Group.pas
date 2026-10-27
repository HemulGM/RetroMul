unit RM.Settings.Template.Group;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects,
  FMX.Controls.Presentation;

type
  TSettingsGroupTemplate = class(TFrame)
    PanelSetting: TPanel;
    LabelSettingTitle: TLabel;
  end;

implementation

{$R *.fmx}

end.

