# Identity
```
system_profiler SPHardwareDataType | grep -Ei "Model Name|Chip|Memory|Serial|Activation Lock"
```

# Activation Lock / Find My
```
nvram -p | grep -i fmm-mobileme-token-FMM   # any output = Find My still armed
```

# MDM enrollment
```
profiles status -type enrollment
sudo profiles show -type enrollment         # detail: org name, MDM server URL
sudo profiles list                          # any installed config profiles
system_profiler SPConfigurationProfileDataType
```

# Tamper / security posture
```
csrutil status                              # want: enabled
bputil -d                                   # want: Full Security, no downgrade
sudo fdesetup status                        # FileVault; should be Off on a clean resale unit
```
