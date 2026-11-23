unit RM.Platforms.NES.Controls.SenarioLcd;

interface

uses
  System.Classes, FMX.Types, FMX.Controls, FMX.Forms, FMX.Layouts, FMX.StdCtrls,
  FMX.Controls.Presentation;

type
  TFrameSenarioLcd = class(TFrame)
    LayoutDisplay: TLayout;
    ButtonLcd: TButton;
    LabelLcdText: TLabel;
    procedure ButtonLcdClick(Sender: TObject);
  public
    procedure UpdateText(const TopLine, BottomLine: string);
    procedure HideText;
  end;

implementation

{$R *.fmx}

procedure TFrameSenarioLcd.ButtonLcdClick(Sender: TObject);
begin
  LabelLcdText.Visible := not LabelLcdText.Visible;
end;

procedure TFrameSenarioLcd.UpdateText(const TopLine, BottomLine: string);
begin
  var Text := TopLine + sLineBreak + BottomLine;
  if LabelLcdText.Text <> Text then
    LabelLcdText.Text := Text;
end;

procedure TFrameSenarioLcd.HideText;
begin
  LabelLcdText.Visible := False;
end;

end.

