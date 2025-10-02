## Multiproofs

This is a prototype for what a multiproof system may look like for the OP-stack. 

A 2-of-3 proof system with underlying proof systems TEE, ZK, and OP was chosen based on this [proposal](https://ethereum-magicians.org/t/a-simple-l2-security-and-finalization-roadmap/23309). Advantanges of this design:
- A way for proposals to resolve quickly via the TEE and ZK proof systems
- A way for proposals to resolve permissionlessly via the ZK and OP proof systems
- Ensuring that permissioned systems alone cannot resolve a proposal
- Building upon existing security where any proposal requires the TEE or OP systems to resolve
- Experimental proof systems, mainly ZK, cannot resolve by themselves

This project is also prototyping this [proposal](https://ethereum-magicians.org/t/protecting-zk-based-rollups-against-invalid-proposals-that-pass-verification/25105), where an automated system is implemented in the proof system to protect against soundness issues.

## Usage

### Make deps

```shell
$ make deps
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
