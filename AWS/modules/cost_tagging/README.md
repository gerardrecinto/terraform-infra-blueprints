# Cost tag consistency and reporting

This module configures an AWS Organizations tag policy, activates cost allocation tags, and creates per-team budgets.

The policy standardizes the case of configured tag keys on supported resource types. It does not add tags, and its `tag_key` plus `enforced_for` rules do not reject resources that omit those keys. The `required_tags` input is retained for compatibility; it names the keys this module configures, rather than a guarantee that every resource has them.

If you need creation requests to fail when tags are missing, design and test service-specific service control policies or IAM conditions separately. This module does not create those controls. Budget results also depend on resources being tagged correctly and cost allocation tags being activated.

Source: [AWS tag policy behavior](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html), [AWS tag policy best practices](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies-best-practices.html).
