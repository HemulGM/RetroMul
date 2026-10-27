unit RM.Settings.Template.Device;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects,
  FMX.Controls.Presentation;

type
  TSettingsDeviceTemplate = class(TFrame)
    PanelSetting: TPanel;
    LayoutSettingText: TLayout;
    LabelSettingTitle: TLabel;
    LabelSettingDetail: TLabel;
    LayoutSettingEditorContainer: TLayout;
    LayoutBindingFooter: TLayout;
    LabelBindingCaption: TLabel;
    LayoutPadEditors: TLayout;
    ButtonPadEditorsCapture: TButton;
    ButtonPadEditorsClear: TButton;
    PathPadEditorsClearIcon: TPath;
    LayoutBindingBody: TLayout;
    LayoutPadAssignments: TLayout;
    LayoutPadAssignmentList: TLayout;
    LayoutBindingPreview: TLayout;
  end;

implementation

{$R *.fmx}

end.

