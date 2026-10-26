package com.fqapp.fqapp

internal object UpdateIdentityPolicy {
    fun verify(installedPackage: String, incomingPackage: String, current: Long, incoming: Long,
               expected: Long, trusted: Set<String>, signers: Set<String>) {
        require(incomingPackage == installedPackage) { "包名不匹配，已阻止安装" }
        require(incoming == expected && expected > current) { "版本号不正确或不是更新版本" }
        require(trusted.isNotEmpty() && signers == trusted) { "签名与当前应用不同，已阻止安装；请勿卸载旧版" }
    }
}
