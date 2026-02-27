mod tokenizer;
mod text;

rustler::init!("Elixir.OptimalSystemAgent.NIF", [
    tokenizer::count_tokens,
    text::calculate_weight,
    text::word_count,
]);
