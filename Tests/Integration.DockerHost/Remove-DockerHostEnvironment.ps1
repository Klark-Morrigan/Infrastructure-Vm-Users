# ---------------------------------------------------------------------------
# Remove-DockerHostEnvironment.ps1
#   Shared AfterAll body for DockerHost integration tests. Dot-source this
#   file inside an AfterAll block after any test-specific cleanup:
#       AfterAll {
#           & bash -c '...'   # test-specific artifact cleanup
#           . "$PSScriptRoot\Remove-DockerHostEnvironment.ps1"
#       }
# ---------------------------------------------------------------------------

if ($null -ne $Script:SshClient) {
    if ($Script:SshClient.IsConnected) { $Script:SshClient.Disconnect() }
    $Script:SshClient.Dispose()
}
& bash -c "userdel -r ${Script:AdminUser} 2>/dev/null" | Out-Null
