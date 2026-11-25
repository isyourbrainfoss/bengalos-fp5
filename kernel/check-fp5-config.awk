# Fail unless the merged 7.2.8-sc7280-fp5+ config has the desk delta.
BEGIN {
    need["CONFIG_QCOMTEE"] = "y"
    need["CONFIG_QCOM_TZMEM_MODE_GENERIC"] = "y"
    need["CONFIG_QCOM_QSEECOM"] = "y"
    need["CONFIG_SND_SOC_QDSP6_Q6VOICE"] = "m"
    need["CONFIG_SND_SOC_QDSP6_Q6VOICE_DAI"] = "m"
    need["CONFIG_XFRM_USER"] = "y"
    need["CONFIG_INET_ESP"] = "y"
    need["CONFIG_INET6_ESP"] = "y"
    need["CONFIG_VIDEO_IMX800"] = "m"
    need["CONFIG_MISC_FOCALTECH_FP"] = "m"
    need["CONFIG_CMA_SIZE_MBYTES"] = "16"
    need["CONFIG_LOCALVERSION"] = "\"-sc7280-fp5+\""
    need["CONFIG_DRM_PANEL_RAYDIUM_RM692E5"] = "m"
    off["CONFIG_NFC"] = 1
    off["CONFIG_QCOM_TZMEM_MODE_SHMBRIDGE"] = 1
    bad = 0
}
/^CONFIG_[A-Za-z0-9_]+=/ {
    k = $0
    sub(/=.*/, "", k)
    v = substr($0, length(k) + 2)
    have[k] = v
}
/^# CONFIG_[A-Za-z0-9_]+ is not set$/ {
    have[$2] = "n"
}
END {
    for (k in need) {
        got = (k in have ? have[k] : "<missing>")
        printf "cfg %s=%s\n", k, got
        if (got != need[k])
            bad = 1
    }
    for (k in off) {
        got = (k in have ? have[k] : "n")
        printf "cfg %s=%s\n", k, got
        if (got != "n")
            bad = 1
    }
    exit bad
}
