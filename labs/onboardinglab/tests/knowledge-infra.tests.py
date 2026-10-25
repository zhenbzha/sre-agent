"""Offline checks of the compiled Foundry dependency and RBAC contracts."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid


INFRA = Path(__file__).resolve().parents[1] / "knowledge" / "infra"
GUID_NAMESPACE = uuid.UUID("11fb06fb-712d-4ddd-98c7-e71bbd588830")


def resources(template):
    items = template["resources"]
    return list(items.values()) if isinstance(items, dict) else items


def deployment(template, name):
    matches = [item for item in resources(template) if item["name"] == name]
    if len(matches) != 1:
        raise AssertionError(f"Expected exactly one deployment named {name}")
    return matches[0]


def arm_guid(*parts):
    # Microsoft documents UUID v5 with this namespace and '-' joined seed values.
    return str(uuid.uuid5(GUID_NAMESPACE, "-".join(parts)))


class KnowledgeInfrastructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cli = shutil.which("az")
        if cli is None:
            raise RuntimeError("Azure CLI with the existing Bicep compiler is required.")
        with tempfile.TemporaryDirectory(prefix="scm-knowledge-bicep-") as directory:
            output = Path(directory) / "main.json"
            subprocess.run(
                [cli, "bicep", "build", "--file", str(INFRA / "main.bicep"),
                 "--outfile", str(output)],
                check=True, capture_output=True, text=True, timeout=120,
            )
            cls.template = json.loads(output.read_text(encoding="utf-8"))
        cls.knowledge = deployment(cls.template, "scm-knowledge")
        cls.connection = deployment(cls.knowledge["properties"]["template"], "project-connection")
        cls.reader = deployment(cls.connection["properties"]["template"], "project-search-reader")
        cls.reader_template = cls.reader["properties"]["template"]
        cls.role = resources(cls.reader_template)[0]

    def test_project_identity_is_read_only_inside_the_dependent_module(self):
        self.assertEqual(set(self.connection["dependsOn"]), {"search", "foundry"})
        parent = self.knowledge["properties"]["template"]
        self.assertFalse(any(
            item["type"] == "Microsoft.CognitiveServices/accounts/projects"
            for item in resources(parent)
        ))
        self.assertEqual(
            self.reader["properties"]["parameters"]["principalId"]["value"],
            "[reference(resourceId('Microsoft.CognitiveServices/accounts/projects', "
            "parameters('foundryName'), parameters('projectName')), "
            "'2025-12-01', 'full').identity.principalId]",
        )

    def test_role_is_reader_only_at_the_search_scope(self):
        self.assertEqual(self.role["type"], "Microsoft.Authorization/roleAssignments")
        self.assertEqual(self.role["scope"],
                         "[resourceId('Microsoft.Search/searchServices', parameters('searchName'))]")
        self.assertEqual(self.role["properties"], {
            "principalId": "[parameters('principalId')]",
            "principalType": "ServicePrincipal",
            "roleDefinitionId": "[variables('readerRole')]",
        })
        self.assertEqual(
            self.reader_template["variables"]["readerRole"],
            "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', "
            "'1407120a-92aa-4202-b7e9-c0e197c71c8f')]",
        )

    def test_compiled_assignment_names_use_the_principal_except_for_legacy_identity(self):
        self.assertEqual(
            self.role["name"],
            "[if(equals(parameters('principalId'), parameters('legacyPrincipalId')), "
            "guid(resourceId('Microsoft.Search/searchServices', parameters('searchName')), "
            "parameters('projectResourceId'), variables('readerRole')), "
            "guid(resourceId('Microsoft.Search/searchServices', parameters('searchName')), "
            "parameters('principalId'), variables('readerRole')))]",
        )
        scope = "/subscriptions/test/resourceGroups/test/providers/Microsoft.Search/searchServices/test"
        project = "/subscriptions/test/resourceGroups/test/providers/Microsoft.CognitiveServices/accounts/test/projects/test"
        role = "/subscriptions/test/providers/Microsoft.Authorization/roleDefinitions/search-reader"
        original = "11111111-1111-1111-1111-111111111111"
        recreated = "22222222-2222-2222-2222-222222222222"
        old_name = arm_guid(scope, project, role)
        original_name = arm_guid(scope, original, role)
        recreated_name = arm_guid(scope, recreated, role)
        self.assertEqual(original_name, arm_guid(scope, original, role))
        self.assertEqual(recreated_name, arm_guid(scope, recreated, role))
        self.assertEqual(len({old_name, original_name, recreated_name}), 3)

    def test_legacy_principal_reaches_the_role_module_and_defaults_to_unset(self):
        self.assertEqual(self.template["parameters"]["legacyProjectPrincipalId"]["defaultValue"], "")
        for module in (self.knowledge, self.connection):
            self.assertEqual(
                module["properties"]["parameters"]["legacyProjectPrincipalId"]["value"],
                "[parameters('legacyProjectPrincipalId')]",
            )
        self.assertEqual(
            self.reader["properties"]["parameters"]["legacyPrincipalId"]["value"],
            "[parameters('legacyProjectPrincipalId')]",
        )
        parameters = json.loads((INFRA / "main.parameters.json").read_text(encoding="utf-8"))
        self.assertEqual(
            parameters["parameters"]["legacyProjectPrincipalId"]["value"],
            "${KNOWLEDGE_LEGACY_PROJECT_PRINCIPAL_ID=}",
        )


if __name__ == "__main__":
    unittest.main()
