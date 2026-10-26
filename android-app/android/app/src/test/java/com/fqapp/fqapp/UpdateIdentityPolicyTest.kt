package com.fqapp.fqapp
import org.junit.Assert.assertThrows
import org.junit.Test

class UpdateIdentityPolicyTest {
    private fun verify(pkg: String = "com.fqapp.fqapp", current: Long = 137, incoming: Long = 138,
                       expected: Long = 138, trusted: Set<String> = setOf("same"), signers: Set<String> = setOf("same")) =
        UpdateIdentityPolicy.verify("com.fqapp.fqapp", pkg, current, incoming, expected, trusted, signers)
    @Test fun acceptsSamePackageSignerAndHigherVersion() { verify() }
    @Test fun blocksDifferentPackage() { assertThrows(IllegalArgumentException::class.java) { verify(pkg = "other") } }
    @Test fun blocksDifferentSigner() { assertThrows(IllegalArgumentException::class.java) { verify(signers = setOf("other")) } }
    @Test fun blocksEmptySigner() { assertThrows(IllegalArgumentException::class.java) { verify(trusted = emptySet(), signers = emptySet()) } }
    @Test fun blocksDowngradeAndEqualVersion() {
        assertThrows(IllegalArgumentException::class.java) { verify(incoming = 136, expected = 136) }
        assertThrows(IllegalArgumentException::class.java) { verify(incoming = 137, expected = 137) }
    }
    @Test fun blocksManifestVersionMismatch() { assertThrows(IllegalArgumentException::class.java) { verify(expected = 139) } }
}
