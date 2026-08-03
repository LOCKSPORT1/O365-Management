Describe 'Get-ToolkitGroupMember Unit Tests' {
    Context 'Parameter Validation and Mocking' {
        It 'Should exist as a loaded public command in the Entra module' {
            $testCmd = Get-Command Get-ToolkitGroupMember -ErrorAction SilentlyContinue
            $testCmd | Should -Not -BeNullOrEmpty
        }

        It 'Should define GroupId parameter as mandatory' {
            $moduleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
            $functionPath = Join-Path -Path $moduleRoot -ChildPath 'O365Toolkit.Entra\Public\Get-ToolkitGroupMember.ps1'
            
            Test-Path -LiteralPath $functionPath -PathType Leaf | Should -BeTrue

            $tokens = $null
            $parseErrors = $null
            $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $functionPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            
            @($parseErrors).Count | Should -Be 0

            $functionAst = $sourceAst.Find(
                {
                    param($AstNode)
                    $AstNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $AstNode.Name -eq 'Get-ToolkitGroupMember'
                },
                $true
            )
            
            $functionAst | Should -Not -BeNullOrEmpty

            $groupIdParameter = @(
                $functionAst.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'GroupId' }
            ) | Select-Object -First 1

            $groupIdParameter | Should -Not -BeNullOrEmpty

            $isMandatory = $false
            foreach ($attribute in $groupIdParameter.Attributes) {
                if ($attribute.TypeName.Name -ne 'Parameter') { continue }
                foreach ($namedArgument in $attribute.NamedArguments) {
                    if ($namedArgument.ArgumentName -ne 'Mandatory') { continue }
                    if ($null -eq $namedArgument.Argument -or $namedArgument.Argument.SafeGetValue() -eq $true) {
                        $isMandatory = $true
                    }
                }
            }

            $isMandatory | Should -BeTrue
        }
    }
}
