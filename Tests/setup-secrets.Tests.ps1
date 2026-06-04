<#
.SYNOPSIS
    Behavioural unit tests for setup-secrets.ps1.

.DESCRIPTION
    setup-secrets.ps1 has top-level side effects (module install/import,
    vault initialisation) so it cannot be dot-sourced safely from a
    test. The harness copies the script into a temp dir alongside empty
    stub files for every dot-source it performs, then invokes the shim
    through `& $shimPath`.

    The mocked seam is Initialize-MicrosoftPowerShellSecretStoreVault -
    the SecretManagement bootstrap is not on the box, and the
    assertions care only about what *this* script forwards to it:

      - SecretName is built as `VmUsersConfig-<SecretSuffix>` so each
        lifecycle gets an isolated vault key.
      - SecretSuffix is consumed locally and must NOT be splatted onto
        Initialize-MicrosoftPowerShellSecretStoreVault (that cmdlet has
        no such parameter, so a splat would error out).
      - ConfigFile / ConfigJson / RequireVaultPassword pass through
        unchanged when supplied.

    Param-contract checks (Mandatory + ValidateNotNullOrEmpty) sit at
    the bottom and are AST-based - they pin the surface even when the
    behavioural path is skipped.
#>

BeforeAll {
    $script:realPath = Join-Path $PSScriptRoot '..\hyper-v\ubuntu\setup-secrets.ps1'

    $script:shimDir = Join-Path ([IO.Path]::GetTempPath()) `
        ("setup-secrets-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory `
        -Path (Join-Path $script:shimDir 'reconcile\common') -Force | Out-Null

    foreach ($rel in @(
        'reconcile\common\ConvertFrom-VmUsersConfigJson.ps1',
        'Install-ModuleDependencies.ps1'
    )) {
        Set-Content -LiteralPath (Join-Path $script:shimDir $rel) -Value '' `
            -Encoding UTF8
    }

    Copy-Item -LiteralPath $script:realPath `
        -Destination (Join-Path $script:shimDir 'setup-secrets.ps1')
    $script:shimPath = Join-Path $script:shimDir 'setup-secrets.ps1'

    # Stub the seam. The real cmdlet lives in Infrastructure.Secrets and
    # is exercised in that repo's suite; here we only assert what
    # setup-secrets passes to it. Params declared so ParameterFilter can
    # bind them.
    function Initialize-MicrosoftPowerShellSecretStoreVault {
        param(
            [string]      $VaultName,
            [string]      $SecretName,
            [string]      $ConfigJson,
            [string]      $ConfigFile,
            [switch]      $RequireVaultPassword,
            [scriptblock] $Validate
        )
    }

    # ConvertTo-Array is called inside the -Validate block. The block
    # is never executed by the stubbed cmdlet, so the stub is only here
    # so the script's dot-source path resolves without errors at the
    # host session level.
    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }
}

AfterAll {
    if ($script:shimDir -and (Test-Path -LiteralPath $script:shimDir)) {
        Remove-Item -LiteralPath $script:shimDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

Describe 'setup-secrets.ps1 - vault initialisation wiring' {

    BeforeEach {
        Mock Initialize-MicrosoftPowerShellSecretStoreVault { }
        Mock Write-Host { }
    }

    # ------------------------------------------------------------------
    Context 'SecretName is built with the suffix' {
    # ------------------------------------------------------------------

        It 'forwards SecretName as VmUsersConfig dash suffix' {
            & $script:shimPath -ConfigJson '{}' -SecretSuffix 'Production'
            Should -Invoke Initialize-MicrosoftPowerShellSecretStoreVault `
                -Times 1 -Exactly -ParameterFilter {
                    $VaultName  -eq 'VmUsers' -and
                    $SecretName -eq 'VmUsersConfig-Production'
                }
        }

        It 'uses the literal suffix without normalising case or punctuation' {
            & $script:shimPath -ConfigJson '{}' -SecretSuffix 'CI-pr-42'
            Should -Invoke Initialize-MicrosoftPowerShellSecretStoreVault `
                -Times 1 -Exactly -ParameterFilter {
                    $SecretName -eq 'VmUsersConfig-CI-pr-42'
                }
        }
    }

    # ------------------------------------------------------------------
    Context 'splat-allowlist filters SecretSuffix out of $initParams' {
    # ------------------------------------------------------------------

        # The script builds $initParams by enumerating a fixed key list
        # (ConfigJson, ConfigFile, RequireVaultPassword) rather than
        # splatting $PSBoundParameters wholesale. If a future contributor
        # collapses that to @PSBoundParameters, SecretSuffix would be
        # passed to Initialize-MicrosoftPowerShellSecretStoreVault, which
        # rejects unknown params and erroring the operator path. These
        # tests pin the filter so that regression fails the suite, not
        # the operator.

        It 'forwards -ConfigJson when supplied' {
            & $script:shimPath -ConfigJson '{"vmName":"node"}' -SecretSuffix 'Production'
            Should -Invoke Initialize-MicrosoftPowerShellSecretStoreVault `
                -Times 1 -Exactly -ParameterFilter {
                    $ConfigJson -eq '{"vmName":"node"}'
                }
        }

        It 'forwards -ConfigFile when supplied (and -ConfigJson stays unset)' {
            & $script:shimPath -ConfigFile 'C:\fake\path.json' -SecretSuffix 'Production'
            Should -Invoke Initialize-MicrosoftPowerShellSecretStoreVault `
                -Times 1 -Exactly -ParameterFilter {
                    $ConfigFile -eq 'C:\fake\path.json' -and
                    -not $ConfigJson
                }
        }

        It 'forwards -RequireVaultPassword when supplied' {
            & $script:shimPath -ConfigJson '{}' -SecretSuffix 'Production' `
                -RequireVaultPassword
            Should -Invoke Initialize-MicrosoftPowerShellSecretStoreVault `
                -Times 1 -Exactly -ParameterFilter {
                    $RequireVaultPassword.IsPresent
                }
        }

        It 'omits -RequireVaultPassword when not supplied' {
            & $script:shimPath -ConfigJson '{}' -SecretSuffix 'Production'
            Should -Invoke Initialize-MicrosoftPowerShellSecretStoreVault `
                -Times 1 -Exactly -ParameterFilter {
                    -not $RequireVaultPassword.IsPresent
                }
        }
    }
}

Describe 'setup-secrets.ps1 - SecretSuffix parameter contract' {

    # AST-based: pins the param-block declaration. The behavioural
    # tests above prove the suffix flows correctly when supplied; these
    # prove the script refuses to run when it is missing or empty.

    BeforeAll {
        $tokens    = $null
        $parseErrs = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:realPath, [ref] $tokens, [ref] $parseErrs)
        if ($parseErrs.Count -gt 0) {
            throw "setup-secrets.ps1 has parse errors: $($parseErrs -join '; ')"
        }
    }

    It 'declares -SecretSuffix as a script parameter' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $param | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix Mandatory' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasMandatory = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'Parameter' -and
            ($_.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            })
        }
        $hasMandatory | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix ValidateNotNullOrEmpty' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasValidator = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'ValidateNotNullOrEmpty'
        }
        $hasValidator | Should -Not -BeNullOrEmpty `
            -Because 'an empty suffix would collide every lifecycle on "VmUsersConfig-"'
    }
}
