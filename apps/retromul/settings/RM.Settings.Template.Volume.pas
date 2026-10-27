unit RM.Settings.Template.Volume;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects,
  FMX.Controls.Presentation;

type
  TSettingsVolumeTemplate = class(TFrame)
    PanelSetting: TPanel;
    LayoutSettingText: TLayout;
    LabelSettingTitle: TLabel;
    LabelSettingDetail: TLabel;
    LayoutSettingEditorContainer: TLayout;
    LayoutVolumeEditor: TLayout;
    LayoutVolumeTrackSlot: TLayout;
    LabelVolumeValue: TLabel;
  end;

implementation

{$R *.fmx}

end.

