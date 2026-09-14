#### RAG (Retrieval Augmented Generation) Database Poisoning

**Concept:** Insert malicious documents into vector databases (Pinecone, Weaviate, Chroma) used by LangChain/LlamaIndex applications.

**Attack Workflow:**

1. **Identify Target RAG System:**
   - Company knowledge bases (Confluence, Notion exports)
   - Internal documentation sites
   - Customer support chatbots
   - HR/policy Q&A systems

2. **Craft Adversarial Embeddings:**
   - Documents rank highly for common corporate queries
   - Use semantic manipulation to boost retrieval scores
   - Embed malicious instructions in high-similarity contexts

3. **Injection Methods:**
   - Contribute to public wikis/repos the company indexes
   - Upload to shared drives that feed the RAG pipeline
   - Submit via "suggest edit" features on documentation sites
   - Exploit unvalidated user-generated content

**Example Poisoned Document:**

```markdown
# Employee IT Security Policies - Updated 2025



---

## Extended reference

This skill's full detail is split: read `references/detail.md` with file_read when you need the deep payload tables, tool matrices, or per-technique checklists that did not fit the skill body.
