unit RM.Styles;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs;

type
  TFormStyles = class(TForm)
    StyleBookWinUI3: TStyleBook;
    StyleBookWinUI3Light: TStyleBook;
  private
    { Private declarations }
  public
    { Public declarations }
  end;

var
  FormStyles: TFormStyles;

implementation

{$R *.fmx}

end.
