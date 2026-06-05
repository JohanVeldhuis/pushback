$ErrorActionPreference = 'Stop'
# Parse-only validation of the GUI script (does NOT show the window).
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\src\Pushback.Gui.ps1),
    [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    Write-Host "PARSE ERRORS:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host $_ }
    exit 1
}
Write-Host "Pushback.Gui.ps1 parses cleanly." -ForegroundColor Green

# Also validate the XAML by loading it into a XamlReader (no window shown).
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml | Out-Null
$xamlPath = Resolve-Path .\src\MainWindow.xaml
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$null = [System.Windows.Markup.XamlReader]::Load($reader)
Write-Host "MainWindow.xaml parses and instantiates cleanly." -ForegroundColor Green
